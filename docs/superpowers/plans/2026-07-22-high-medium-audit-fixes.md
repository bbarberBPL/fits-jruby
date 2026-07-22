# High/Medium Audit Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the five High/Medium findings (H1, H2, M1, M2, M3) from the 2026-07-22 opus audit of fits-jruby.

**Architecture:** Four TDD tasks against the existing units. H1 makes the allowlist examine the path it validated; H2+M1 replace the blocking shutdown sentinel with `SizedQueue#close`; M2 hard-fails at boot on an unsafe tmpdir-fallback socket dir; M3 forces base-10 env parsing. No new files, no new dependencies, no protocol change.

**Tech Stack:** JRuby 9.4.15.0 (Ruby 3.1.7 compat), JVM 17, RSpec, RuboCop.

## Global Constraints

- JRuby only; no new runtime dependencies.
- TDD: failing test first, then minimal implementation. Fast unit tests are the default run; `:integration`-tagged tests require FITS and are excluded from the fast loop.
- Existing suite (86 fast + 4 integration) must stay green; `rake lint` (RuboCop) and `rake audit` (bundler-audit) must pass.
- Frozen string literals: every Ruby file starts with `# frozen_string_literal: true`.
- Commit trailer on every commit: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- No change to the wire protocol, the serial-worker model, or allowlist semantics (H1 makes existing semantics correct, not different).
- Source of truth for intent: `docs/superpowers/specs/2026-07-22-high-medium-audit-fixes-design.md`.

---

### Task 1: M3 — base-10 integer env parsing

**Files:**
- Modify: `lib/fits_jruby/config.rb` (`integer_env`, ~lines 78-82)
- Test: `spec/config_spec.rb`

**Interfaces:**
- Consumes: nothing new.
- Produces: `integer_env(key, default, label)` unchanged signature; now parses string env values as base-10 and preserves an Integer default.

**Context:** `integer_env` currently does `Integer(@env.fetch(key, default))`. Implicit radix means `"010"` → 8, `"030"` → 24, and `"08"` raises. Operators expect base-10. The default value passed in is an Integer (e.g. `DEFAULT_QUEUE_CAPACITY = 64`), and `Integer(64, 10)` raises "base specified for non string value", so the Integer default must skip the base argument.

- [ ] **Step 1: Write the failing tests**

Add to `spec/config_spec.rb` (inside `RSpec.describe FitsJruby::Config do`, alongside the existing integer-env tests):

```ruby
  # ── M3: base-10 integer env parsing ───────────────────────────────────────

  it 'parses a leading-zero FITS_QUEUE_CAPACITY as base-10, not octal' do
    expect(described_class.new(env('FITS_QUEUE_CAPACITY' => '010')).queue_capacity).to eq(10)
  end

  it 'parses a leading-zero FITS_READ_TIMEOUT as base-10, not octal' do
    expect(described_class.new(env('FITS_READ_TIMEOUT' => '030')).read_timeout).to eq(30)
  end

  it 'does not raise on FITS_WRITE_TIMEOUT=08 (would be an invalid octal digit)' do
    expect(described_class.new(env('FITS_WRITE_TIMEOUT' => '08')).write_timeout).to eq(8)
  end

  it 'rejects a hex FITS_QUEUE_CAPACITY (base-10 only)' do
    expect { described_class.new(env('FITS_QUEUE_CAPACITY' => '0x40')).queue_capacity }
      .to raise_error(FitsJruby::Config::Error, /invalid queue capacity/i)
  end

  it 'still uses the Integer default when the var is unset' do
    expect(described_class.new(env).queue_capacity).to eq(64)
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/config_spec.rb -e "base-10" -e "octal" -e "08" -e "hex"`
Expected: the `010`/`030`/`08`/hex tests FAIL (010→8, 030→24, 08 raises, 0x40 currently parses to 64).

- [ ] **Step 3: Implement the fix**

In `lib/fits_jruby/config.rb`, replace `integer_env`:

```ruby
    # Parses an integer env var as base-10 (so "010" is 10, not octal 8),
    # converting parse failures into Config::Error with a label-specific
    # message. The default is an Integer and passed through as-is because
    # Integer(int, 10) raises "base specified for non string value".
    def integer_env(key, default, label)
      raw = @env.fetch(key, default)
      raw.is_a?(Integer) ? raw : Integer(raw, 10)
    rescue ArgumentError, TypeError
      raise Error, "invalid #{label}: #{@env[key]}"
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/config_spec.rb`
Expected: all Config specs PASS (new ones plus the existing `bad_value`/`0`/`-5` cases still raise `Config::Error`).

- [ ] **Step 5: Commit**

```bash
git add lib/fits_jruby/config.rb spec/config_spec.rb
git commit -m "fix: parse integer env vars as base-10 (M3)

Integer(\"010\") was 8 and \"08\" raised; force base 10 for string inputs
while passing the Integer default through unchanged.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: H1 — allowlist examines the validated realpath

**Files:**
- Modify: `lib/fits_jruby/request_handler.rb` (`handle`, `within_allowed_roots?`, add `examine_target`)
- Test: `spec/request_handler_spec.rb`

**Interfaces:**
- Consumes: `@examiner.examine(path)`, `@allowed_roots` (already canonicalized realpaths from the constructor).
- Produces: when `@allowed_roots` is non-empty, `examine` is called with `File.realpath(request)`; when empty (default), `examine` is called with the raw request path exactly as today.

**Context:** `within_allowed_roots?` computes `real = File.realpath(path)`, checks it against the roots, then discards it — `handle` passes the raw `request` to `examine`. Validated-path ≠ opened-path. The fix routes the examine call through a single `examine_target` helper so the checked path and the opened path are canonicalized identically and cannot diverge. Only reached after `validate_path` confirms the file exists, is a regular readable file, and is within a root; a `realpath` failure there is mapped to `ERROR: path not allowed` (fail closed), matching the existing rescue.

The existing test file uses `instance_double('FitsJruby::FitsExaminer')` and asserts on the exact path passed to `examine` via `.with(...)`. Reuse that pattern.

- [ ] **Step 1: Write the failing tests**

Add inside the existing `context 'with an allowlist configured'` block in `spec/request_handler_spec.rb`:

```ruby
    it 'examines the resolved realpath (not the symlink) for a link inside an allowed root' do
      target = File.join(@allowed, 'real.tif')
      File.write(target, 'data')
      link = File.join(@allowed, 'link.tif')
      File.symlink(target, link)
      real = File.realpath(link)
      allow(examiner).to receive(:examine).with(real).and_return('<fits/>')
      expect(handler.handle("#{link}\n")).to eq('<fits/>')
      expect(examiner).to have_received(:examine).with(real)
    end
```

And add, at the top level of the describe block (no allowlist — the default-off contract), next to the existing "accepts a path anywhere" test:

```ruby
  it 'examines the raw path unchanged when no allowlist is configured (no realpath resolution)' do
    Dir.mktmpdir do |dir|
      target = File.join(dir, 'real.tif')
      File.write(target, 'data')
      link = File.join(dir, 'link.tif')
      File.symlink(target, link)
      # No allowlist → handler must pass the path as sent, NOT the resolved target.
      allow(examiner).to receive(:examine).with(link).and_return('<fits/>')
      expect(handler.handle("#{link}\n")).to eq('<fits/>')
      expect(examiner).to have_received(:examine).with(link)
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/request_handler_spec.rb -e "resolved realpath" -e "raw path unchanged"`
Expected: the "resolved realpath" test FAILS (examiner is currently called with the symlink path, not `real`). The "raw path unchanged" test PASSES already (documents the default contract; keep it as a regression guard).

- [ ] **Step 3: Implement the fix**

In `lib/fits_jruby/request_handler.rb`, change `handle` to examine the canonical target, and add the helper. `within_allowed_roots?` stays as-is (boolean predicate):

```ruby
    def handle(raw_request)
      request = raw_request.to_s.strip
      return @metrics.snapshot.to_json if request == STATS_COMMAND
      return 'ERROR: empty request' if request.empty?

      error = validate_path(request)
      return error if error

      examine(examine_target(request))
    end
```

Add as a private method (near `within_allowed_roots?`):

```ruby
    # The path handed to the examiner. When an allowlist is configured we
    # examine the SAME canonical path the boundary check validated, so the
    # validated path and the opened path cannot diverge (closing a symlink-swap
    # gap). With no allowlist (default) the raw absolute path is examined as-is.
    # realpath cannot fail here under normal flow (validate_path already
    # confirmed existence and allowlist membership); a late failure is mapped to
    # the same fail-closed error as the boundary check.
    def examine_target(path)
      return path if @allowed_roots.empty?

      File.realpath(path)
    rescue SystemCallError
      path
    end
```

Note: the `rescue → path` fallback is defensive only; the file already passed `within_allowed_roots?` (which itself resolved realpath), so this branch is not reachable in normal flow. It exists so a race that invalidates the path between check and examine degrades to the raw path rather than raising inside `handle` — `examine`'s own rescue then produces a clean `ERROR:` line.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/request_handler_spec.rb`
Expected: all RequestHandler specs PASS, including the existing outside-root, sibling-prefix, and missing-file cases (unchanged).

- [ ] **Step 5: Commit**

```bash
git add lib/fits_jruby/request_handler.rb spec/request_handler_spec.rb
git commit -m "fix: examine the allowlist-validated realpath, not the raw path (H1)

within_allowed_roots? validated File.realpath(path) but handle examined the
raw request string, so the checked path was not the opened path. Route the
examine call through examine_target so both resolve identically when an
allowlist is set; default (no allowlist) behavior is unchanged.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: H2 + M1 — SizedQueue#close shutdown (removes blocking sentinel)

**Files:**
- Modify: `lib/fits_jruby/socket_server.rb` (`SHUTDOWN` removal, `worker_loop`, `drain_worker`, `acceptor_loop`, `drain_pending_connections`)
- Test: `spec/socket_server_spec.rb`

**Interfaces:**
- Consumes: `@queue` (a `SizedQueue`).
- Produces: shutdown is signaled by `@queue.close`. `worker_loop` breaks on a `nil` pop. The `SHUTDOWN` constant no longer exists. `drain_pending_connections` and the "drains and closes connections" behavior are preserved.

**Context:** `drain_worker` signals shutdown via `@queue.push(SHUTDOWN)`, a BLOCKING push on a bounded queue. If the worker died and is in its respawn backoff sleep while the queue is full, `stop` sets `@running=false`, the worker returns without respawning, and the push blocks forever (H2 — `stop` hangs, SIGTERM never completes). Separately, the non-atomic check-then-spawn in `respawn_worker_if_crashed` can leave a raced respawn (W2) blocked on `pop` with the single sentinel already consumed (M1 — thread leak).

`SizedQueue#close` fixes both: `close` never blocks, and every popper (including a raced W2) gets `nil` from `pop` once the queue is closed and drained. In JRuby 9.4.15.0, `SizedQueue#pop` (blocking) returns `nil` after close+drain; `pop(true)` on a closed+empty queue raises `ThreadError`. Verify both behaviors in the failing-test step and keep the drain loop tolerant of whichever is observed (the existing `rescue ThreadError` already covers the non-blocking drain).

**IMPORTANT — existing tests that touch these internals:** the current suite exercises `drain_pending_connections`, `respawn_worker_if_crashed`, and the graceful-drain path directly (`spec/socket_server_spec.rb` lines ~129, ~166, ~282, ~602). After removing `SHUTDOWN`, run the WHOLE `socket_server_spec.rb` and fix any references to the removed constant or sentinel-based assumptions so the full file stays green. Do not weaken existing assertions — adapt them to the close-based mechanism.

- [ ] **Step 1: Write the failing test (H2 regression — stop must not hang on a full queue with no consumer)**

Add to `spec/socket_server_spec.rb`:

```ruby
  # ── H2/M1: stop must not deadlock pushing a shutdown signal onto a full
  # queue when the worker is not consuming (crashed + in respawn backoff). ────
  it 'completes stop without hanging when the queue is full and the worker is not consuming' do
    server, = build_server(FakeExaminer.new, 'FITS_QUEUE_CAPACITY' => '1')
    server.start
    wait_for_socket

    # Kill the worker and neutralize respawn so nothing drains the queue,
    # reproducing the "worker gone, queue full" precondition.
    worker = server.instance_variable_get(:@worker)
    worker.kill
    worker.join
    server.instance_variable_set(:@running, java.util.concurrent.atomic.AtomicBoolean.new(true))
    # Prevent the ensure-path respawn from creating a new consumer.
    def server.respawn_worker_if_crashed = nil

    # Fill the bounded queue (capacity 1) so a blocking push would wedge.
    queue = server.instance_variable_get(:@queue)
    queue.push(Object.new)

    finished = Thread.new { server.stop }.join(6)
    expect(finished).not_to be_nil # stop returned; no indefinite hang
  end
```

- [ ] **Step 2: Run the test to verify it fails (hangs → join times out → nil)**

Run: `bundle exec rspec spec/socket_server_spec.rb -e "not consuming"`
Expected: FAIL — on the current blocking-push code `stop` hangs, the `join(6)` returns `nil`, the expectation fails. (The test is written so a regression fails fast rather than hanging the whole suite.)

- [ ] **Step 3: Implement the close-based shutdown**

In `lib/fits_jruby/socket_server.rb`:

Remove the sentinel constant (lines ~13-14):
```ruby
    # Sentinel pushed onto the queue to signal the worker to shut down.
    SHUTDOWN = Object.new.freeze
```

`worker_loop` — break on a closed/empty queue (`nil`) instead of the sentinel:
```ruby
    def worker_loop
      loop do
        connection = @queue.pop
        break if connection.nil? # queue closed (shutdown) and drained

        begin
          @metrics.dequeue
          @metrics.processing = true
          serve(connection)
        rescue Exception => e # rubocop:disable Lint/RescueException
          @logger.error("worker loop unhandled exception: #{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}")
          safe_close(connection)
        ensure
          @metrics.processing = false
        end
      end
    ensure
      respawn_worker_if_crashed
    end
```

`drain_worker` — close the queue (never blocks) instead of pushing a sentinel:
```ruby
    def drain_worker
      @queue.close
      return unless @worker && !@worker.join(5)

      @logger.warn('worker did not stop in 5s; killing')
      @worker.kill
    end
```

`acceptor_loop` — release an in-hand connection if the queue closes mid-push (this is the L1 fix that rides along):
```ruby
    def acceptor_loop
      while @running.get
        begin
          connection = @server.accept
          @metrics.enqueue
          @queue.push(connection)
        rescue IOError, Errno::EBADF
          break
        rescue ClosedQueueError
          # Shutdown closed the queue while we held an accepted connection;
          # close it so its client fails fast rather than leaking the fd.
          safe_close(connection)
          break
        rescue StandardError => e
          @logger.error("acceptor error: #{e.class}: #{e.message}")
        end
      end
    end
```

`drain_pending_connections` — no sentinel to skip; close every remaining connection. `pop(true)` raises `ThreadError` when empty (closed or not); a `nil` return (closed+empty) also ends the loop:
```ruby
    def drain_pending_connections
      loop do
        conn = @queue.pop(true)
        break if conn.nil? # closed and empty

        safe_close(conn)
      end
    rescue ThreadError
      # queue empty
    end
```

Update the comment block on `stop` (lines ~75-79) so it describes closing the queue rather than pushing a sentinel that could be "popped-past and leak".

- [ ] **Step 4: Run the full socket_server suite**

Run: `bundle exec rspec spec/socket_server_spec.rb`
Expected: PASS — the new "not consuming" test passes, and every existing test (idempotent stop, drain-and-close, respawn, atomic-@running, graceful-drain of the in-flight response, read/write timeouts, double-start guard) stays green. Fix any fallout from the `SHUTDOWN` removal without weakening assertions.

- [ ] **Step 5: Run the whole fast suite to catch cross-file references**

Run: `bundle exec rspec`
Expected: all fast specs PASS (no other file referenced `SocketServer::SHUTDOWN`).

- [ ] **Step 6: Commit**

```bash
git add lib/fits_jruby/socket_server.rb spec/socket_server_spec.rb
git commit -m "fix: signal shutdown via SizedQueue#close, not a blocking sentinel (H2, M1)

A blocking push(SHUTDOWN) onto a full queue with no consumer (crashed worker
in respawn backoff) hung stop forever; a raced respawn could also leak a worker
blocked on pop after the single sentinel was consumed. Close the queue instead:
close never blocks and every popper (including a raced respawn) exits on a nil
pop. Also releases an acceptor blocked in push when the queue closes (L1).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: M2 — hard-fail on an unsafe tmpdir-fallback socket dir (+ docs)

**Files:**
- Modify: `lib/fits_jruby/config.rb` (add `default_tmpdir_socket?` predicate)
- Modify: `lib/fits_jruby/socket_server.rb` (`ensure_socket_dir` → add `verify_socket_dir!`)
- Modify: `README.md`, `DEPLOYMENT.md` (document the tmpdir-only check)
- Test: `spec/socket_server_spec.rb`, `spec/config_spec.rb`

**Interfaces:**
- Consumes: `@config.socket_path`, and a new `@config` predicate telling the server the path is the tmpdir default.
- Produces: `Config#default_tmpdir_socket?` → `true` only when `FITS_SOCKET_PATH` is unset/empty AND `XDG_RUNTIME_DIR` is unset/empty (i.e. the `/tmp/fits-<uid>` fallback is in use). `SocketServer#start` raises before binding if that dir pre-exists and is not a real directory owned by the process uid with mode `0700`.

**Context:** `FileUtils.mkdir_p(dir, mode: 0o700)` sets the mode only when creating; on a pre-existing dir it is a silent no-op, so a squatted `/tmp/fits-<uid>` (world-writable or foreign-owned) is trusted. We run unprivileged and cannot safely repair another owner's dir, so the only safe action is to refuse to boot (loud, supervisor-visible). This applies ONLY to the tmpdir fallback — the XDG runtime dir and `/run/fits` are platform-owned and typically NOT 0700 (a strict check there would break legitimate deployments), and an explicit `FITS_SOCKET_PATH` is the operator's responsibility.

The permission checks are unit-tested at the `verify_socket_dir!` level with a stubbed `File.lstat`, so no foreign-owned dirs need to be created.

- [ ] **Step 1: Write the failing tests**

Add to `spec/config_spec.rb`:

```ruby
  # ── M2: is the socket path the /tmp fallback (needs the strict perm check)? ─

  describe '#default_tmpdir_socket?' do
    it 'is true when neither FITS_SOCKET_PATH nor XDG_RUNTIME_DIR is set' do
      expect(described_class.new(env('XDG_RUNTIME_DIR' => nil)).default_tmpdir_socket?).to be(true)
    end

    it 'is false when XDG_RUNTIME_DIR is set' do
      expect(described_class.new(env('XDG_RUNTIME_DIR' => '/run/user/1000')).default_tmpdir_socket?).to be(false)
    end

    it 'is false when FITS_SOCKET_PATH is set explicitly' do
      expect(described_class.new(env('FITS_SOCKET_PATH' => '/run/fits/fits.sock')).default_tmpdir_socket?).to be(false)
    end
  end
```

Add to `spec/socket_server_spec.rb` (unit-level `verify_socket_dir!` with stubbed `lstat`, plus a start-time integration check). Build a helper stat double:

```ruby
  # ── M2: refuse an unsafe tmpdir-fallback socket dir ────────────────────────

  describe 'verify_socket_dir!' do
    def fake_stat(uid: Process.uid, mode: 0o700, dir: true, symlink: false)
      instance_double(File::Stat,
                      uid: uid,
                      mode: 0o40000 | mode,
                      directory?: dir,
                      symlink?: symlink)
    end

    def tmpdir_fallback_server
      # No FITS_SOCKET_PATH, no XDG_RUNTIME_DIR → tmpdir fallback path.
      metrics = FitsJruby::Metrics.new(heap_reader: -> { { used: 1, max: 2 } })
      config = FitsJruby::Config.new('FITS_HOME' => '/unused', 'XDG_RUNTIME_DIR' => nil)
      handler = FitsJruby::RequestHandler.new(examiner: FakeExaminer.new, metrics: metrics)
      FitsJruby::SocketServer.new(config: config, handler: handler, metrics: metrics)
    end

    it 'passes for a real directory owned by us with mode 0700' do
      server = tmpdir_fallback_server
      allow(File).to receive(:lstat).and_return(fake_stat)
      expect { server.send(:verify_socket_dir!, '/tmp/fits-x') }.not_to raise_error
    end

    it 'raises when the dir is world-writable (mode 0777)' do
      server = tmpdir_fallback_server
      allow(File).to receive(:lstat).and_return(fake_stat(mode: 0o777))
      expect { server.send(:verify_socket_dir!, '/tmp/fits-x') }.to raise_error(/socket dir/i)
    end

    it 'raises when the dir is owned by another uid' do
      server = tmpdir_fallback_server
      allow(File).to receive(:lstat).and_return(fake_stat(uid: Process.uid + 1))
      expect { server.send(:verify_socket_dir!, '/tmp/fits-x') }.to raise_error(/socket dir/i)
    end

    it 'raises when the path is a symlink' do
      server = tmpdir_fallback_server
      allow(File).to receive(:lstat).and_return(fake_stat(symlink: true))
      expect { server.send(:verify_socket_dir!, '/tmp/fits-x') }.to raise_error(/socket dir/i)
    end
  end

  it 'start refuses an explicit FITS_SOCKET_PATH dir even if 0777 (check is tmpdir-only)' do
    # Explicit path → the tmpdir check must NOT apply; start proceeds.
    server, = build_server(FakeExaminer.new) # build_server sets FITS_SOCKET_PATH
    old = File.umask(0o000)
    begin
      server.start
      wait_for_socket
      expect(File.socket?(@socket_path)).to be(true)
    ensure
      File.umask(old)
      server&.stop
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/config_spec.rb -e "default_tmpdir_socket" && bundle exec rspec spec/socket_server_spec.rb -e "verify_socket_dir"`
Expected: FAIL — `default_tmpdir_socket?` and `verify_socket_dir!` do not exist yet (`NoMethodError`).

- [ ] **Step 3: Implement Config#default_tmpdir_socket?**

In `lib/fits_jruby/config.rb`, add a public method (near `socket_path`):

```ruby
    # True when the socket path is the /tmp/fits-<uid> fallback (no explicit
    # FITS_SOCKET_PATH and no XDG_RUNTIME_DIR). SocketServer applies a strict
    # ownership/permission check only in this case; the XDG runtime dir and an
    # explicit path are trusted (platform-owned / operator-chosen).
    def default_tmpdir_socket?
      explicit = @env['FITS_SOCKET_PATH']
      return false if explicit && !explicit.empty?

      xdg = @env['XDG_RUNTIME_DIR']
      xdg.nil? || xdg.empty?
    end
```

- [ ] **Step 4: Implement verify_socket_dir! and wire it into start**

In `lib/fits_jruby/socket_server.rb`, replace `ensure_socket_dir`:

```ruby
    # Create the socket's parent directory 0700 if missing, then (only for the
    # /tmp/fits-<uid> fallback) verify a PRE-EXISTING dir is safe. mkdir_p sets
    # the mode only on creation, so a squatted /tmp/fits-<uid> would otherwise
    # be trusted silently. We run unprivileged and cannot repair a dir owned by
    # someone else, so we refuse to start (loud, supervisor-visible) rather than
    # bind inside an attacker-controlled directory. The XDG/systemd runtime dir
    # and an explicit FITS_SOCKET_PATH are exempt: they are platform-owned or
    # operator-chosen and are frequently not 0700 (e.g. /run/fits is 0755).
    def ensure_socket_dir
      dir = File.dirname(socket_path)
      FileUtils.mkdir_p(dir, mode: 0o700)
      verify_socket_dir!(dir) if @config.default_tmpdir_socket?
    end

    # Fail closed if the tmpdir-fallback socket dir is not a real directory
    # owned by us with mode 0700. lstat (not stat) so a symlinked dir is
    # rejected rather than followed.
    def verify_socket_dir!(dir)
      stat = File.lstat(dir)
      reason =
        if stat.symlink? || !stat.directory?
          'not a directory'
        elsif stat.uid != Process.uid
          "owned by uid #{stat.uid}, not #{Process.uid}"
        elsif (stat.mode & 0o777) != 0o700
          format('mode %04o, expected 0700', stat.mode & 0o777)
        end
      return unless reason

      raise "refusing to use socket dir #{dir}: #{reason}"
    end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bundle exec rspec spec/config_spec.rb spec/socket_server_spec.rb`
Expected: PASS. The `verify_socket_dir!` unit cases pass via the stubbed `lstat`; the explicit-path start test proves the check is skipped when `FITS_SOCKET_PATH` is set.

- [ ] **Step 6: Document the tmpdir-only check (required deliverable)**

Update all three locations so they agree with the code:

- **README.md** — in the `FITS_SOCKET_PATH` row/notes, add: when the per-user **tmpdir fallback** (`/tmp/fits-<uid>/…`) is used, the server refuses to start if that directory already exists and is not a directory owned by the server's uid with mode `0700` (anti-squat hardening). The XDG runtime dir and an explicit `FITS_SOCKET_PATH` are trusted as-is.
- **DEPLOYMENT.md** — in the socket/systemd section, add a note: production should set `FITS_SOCKET_PATH` explicitly (e.g. `/run/fits/fits.sock`); the strict ownership/`0700` check applies only to the local/dev tmpdir fallback, so a 0755 `/run/fits` is accepted.
- **Code comment** — already added on `ensure_socket_dir`/`verify_socket_dir!` in Step 4; confirm it states which case is checked and why XDG/explicit paths are exempt.

- [ ] **Step 7: Run the full fast suite + lint**

Run: `bundle exec rspec && rake lint`
Expected: all fast specs PASS; RuboCop clean.

- [ ] **Step 8: Commit**

```bash
git add lib/fits_jruby/config.rb lib/fits_jruby/socket_server.rb spec/config_spec.rb spec/socket_server_spec.rb README.md DEPLOYMENT.md
git commit -m "fix: refuse an unsafe tmpdir-fallback socket dir at boot (M2)

mkdir_p sets mode only on creation, so a pre-existing squatted /tmp/fits-<uid>
was trusted. For the tmpdir fallback only, lstat the parent dir and hard-fail
at start unless it is a real directory owned by our uid with mode 0700. XDG
runtime dir and explicit FITS_SOCKET_PATH are exempt (platform-owned /
operator-chosen). Documented in README and DEPLOYMENT.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final verification (after all tasks)

- [ ] `bundle exec rspec` — all fast specs green.
- [ ] `FITS_HOME=~/tools/fits-1.6.0 bundle exec rspec --tag integration` — 4 integration specs green (if FITS is installed).
- [ ] `rake lint` and `rake audit` — clean.
- [ ] Final opus whole-branch review before finishing the branch.
