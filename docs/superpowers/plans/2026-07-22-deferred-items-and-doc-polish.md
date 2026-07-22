# Deferred Items, Convenience API, and Doc Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close out the four deferred audit "Low" findings, add a build/run convenience API to `lib/fits_jruby.rb`, polish the docs, and pin the JRuby version in the Gemfile.

**Architecture:** The top-level `FitsJruby` module gains `build_server` (pure object-graph assembly) and `run!` (validate + build + trap signals + start + sleep); `bin/fits-server` collapses onto `run!`. The socket default moves off shared `/tmp` to a per-user runtime dir, with `SocketServer#start` creating the parent dir and guarding against double-start. The installer refuses non-https redirects. Docs are updated to match.

**Tech Stack:** JRuby 9.4.15.0 (Ruby 3.1.7 compat), RSpec 3.13, RuboCop 1.60, Ruby stdlib only (`socket`, `fileutils`, `tmpdir`, `net/http`).

## Global Constraints

- JRuby only: `ruby '3.1.7', engine: 'jruby', engine_version: '9.4.15.0'` (exact values).
- TDD with RSpec is mandatory: write the failing test first every time.
- Fast unit tests must not require a JVM/FITS; integration tests stay tagged `:integration`.
- No new runtime dependencies; stdlib only.
- RuboCop must stay clean (`Layout/LineLength Max: 120`, `Metrics/MethodLength Max: 25`).
- Commit trailer on every commit: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Do NOT push or configure remotes — only the developer does that.
- Existing suite (86 fast + 4 integration) must stay green.

---

### Task 1: Gemfile Ruby/JRuby version directive

**Files:**
- Modify: `Gemfile:3-4`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing code-facing; documents the engine for Bundler.

- [ ] **Step 1: Add the ruby directive**

Edit `Gemfile` so the top reads:

```ruby
# frozen_string_literal: true

source 'https://rubygems.org'

ruby '3.1.7', engine: 'jruby', engine_version: '9.4.15.0'

gem 'rake', '~> 13.0'

group :development, :test do
  gem 'bundler-audit', '~> 0.9', require: false
  gem 'rspec', '~> 3.13'
  gem 'rubocop', '~> 1.60', require: false
end
```

- [ ] **Step 2: Verify bundler still resolves**

Run: `bundle install`
Expected: completes without a "Your Ruby version ... does not match" error (running under jruby-9.4.15.0 / Ruby 3.1.7).

- [ ] **Step 3: Verify the lockfile records the engine**

Run: `grep -A2 '^RUBY VERSION' Gemfile.lock`
Expected: shows `ruby 3.1.7p... (jruby 9.4.15.0)` block (Bundler writes a `RUBY VERSION` stanza).

- [ ] **Step 4: Commit**

```bash
git add Gemfile Gemfile.lock
git commit -m "build: pin ruby/jruby engine version in Gemfile

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Config per-user runtime dir socket default

**Files:**
- Modify: `lib/fits_jruby/config.rb:8` (constant → method), `lib/fits_jruby/config.rb:23-25` (`socket_path`)
- Test: `spec/config_spec.rb:25-30` (update default assertion) and new examples

**Interfaces:**
- Consumes: `ENV['XDG_RUNTIME_DIR']`, `ENV['FITS_SOCKET_PATH']`, `Dir.tmpdir`, `Process.uid`.
- Produces: `Config#socket_path` returns the explicit `FITS_SOCKET_PATH` when set, else `"#{XDG_RUNTIME_DIR}/fits.sock"` when `XDG_RUNTIME_DIR` is set and non-empty, else `"#{Dir.tmpdir}/fits-#{Process.uid}/fits.sock"`.

- [ ] **Step 1: Write the failing tests**

Replace the default-socket assertion in `spec/config_spec.rb`. First, add `require 'tmpdir'` is already present (line 3). Change the existing example at lines 25-30 so it no longer asserts `/tmp/fits.sock`, and add a focused block. Add these examples inside the `describe`:

```ruby
  describe 'socket_path default (no FITS_SOCKET_PATH)' do
    it 'uses XDG_RUNTIME_DIR when set' do
      config = described_class.new(env('XDG_RUNTIME_DIR' => '/run/user/1000'))
      expect(config.socket_path).to eq('/run/user/1000/fits.sock')
    end

    it 'falls back to a per-uid dir under tmpdir when XDG_RUNTIME_DIR is unset' do
      config = described_class.new(env('XDG_RUNTIME_DIR' => nil))
      expect(config.socket_path).to eq("#{Dir.tmpdir}/fits-#{Process.uid}/fits.sock")
    end

    it 'falls back when XDG_RUNTIME_DIR is empty' do
      config = described_class.new(env('XDG_RUNTIME_DIR' => ''))
      expect(config.socket_path).to eq("#{Dir.tmpdir}/fits-#{Process.uid}/fits.sock")
    end
  end

  it 'prefers an explicit FITS_SOCKET_PATH over the runtime-dir default' do
    config = described_class.new(env(
                                   'FITS_SOCKET_PATH' => '/run/fits/fits.sock',
                                   'XDG_RUNTIME_DIR' => '/run/user/1000'
                                 ))
    expect(config.socket_path).to eq('/run/fits/fits.sock')
  end
```

Then edit the existing example at lines 25-30 to drop the socket_path assertion (leave queue_capacity + log_level):

```ruby
  it 'defaults the queue capacity and log level' do
    config = described_class.new(env)
    expect(config.queue_capacity).to eq(64)
    expect(config.log_level).to eq(:info)
  end
```

Note: `env` builds a hash; passing `'XDG_RUNTIME_DIR' => nil` yields a key with nil value. `@env.fetch('XDG_RUNTIME_DIR', nil)` returns nil → handled as "unset".

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/config_spec.rb -e 'socket_path' -e 'explicit FITS_SOCKET_PATH'`
Expected: FAIL — current default returns `/tmp/fits.sock`.

- [ ] **Step 3: Implement the dynamic default**

In `lib/fits_jruby/config.rb`, add `require 'tmpdir'` at the top (after `# frozen_string_literal: true`). Remove the `DEFAULT_SOCKET_PATH = '/tmp/fits.sock'` constant (line 8) and replace `socket_path` (lines 23-25) with:

```ruby
    def socket_path
      explicit = @env['FITS_SOCKET_PATH']
      return explicit if explicit && !explicit.empty?

      default_socket_path
    end
```

Add this private helper (in the `private` section):

```ruby
    # Per-user socket path so the default is not a shared, predictable path on
    # /tmp (which any local user could pre-create/squat). Prefers the systemd
    # per-user runtime dir when present; otherwise a per-uid subdir of the
    # system temp dir. SocketServer#start creates the parent dir 0700.
    def default_socket_path
      xdg = @env['XDG_RUNTIME_DIR']
      return "#{xdg}/fits.sock" if xdg && !xdg.empty?

      "#{Dir.tmpdir}/fits-#{Process.uid}/fits.sock"
    end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/config_spec.rb`
Expected: PASS (all config examples).

- [ ] **Step 5: Commit**

```bash
git add lib/fits_jruby/config.rb spec/config_spec.rb
git commit -m "feat: default socket to per-user runtime dir instead of /tmp

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: SocketServer creates parent dir and guards double-start

**Files:**
- Modify: `lib/fits_jruby/socket_server.rb:47-60` (`start`)
- Test: `spec/socket_server_spec.rb` (new examples)

**Interfaces:**
- Consumes: `Config#socket_path` (Task 2), `FileUtils.mkdir_p`.
- Produces: `SocketServer#start` creates the socket's parent dir (mode `0700`) if missing before binding, and raises `RuntimeError` ("server already running") if called while `@running.get` is true.

- [ ] **Step 1: Inspect existing start-related specs**

Run: `bundle exec rspec spec/socket_server_spec.rb -e start --dry-run` (to find existing example names; if none match, that's fine).
Then read the top of `spec/socket_server_spec.rb` to learn the existing setup helpers (how a server + tmp socket path is built) and reuse them.

- [ ] **Step 2: Write the failing tests**

Add to `spec/socket_server_spec.rb`, reusing the file's existing helper for constructing a server (match the surrounding style — the examples below assume a `build_server`/`make_server` style helper and a tmp `socket_path`; adapt names to what the file already uses):

```ruby
  describe 'start' do
    it 'creates the socket parent directory (0700) when missing' do
      Dir.mktmpdir do |base|
        sock = File.join(base, 'nested', 'fits.sock')
        server = build_test_server(socket_path: sock)
        server.start
        begin
          dir = File.dirname(sock)
          expect(Dir.exist?(dir)).to be(true)
          expect(File.stat(dir).mode & 0o777).to eq(0o700)
        ensure
          server.stop
        end
      end
    end

    it 'raises if started while already running' do
      Dir.mktmpdir do |base|
        sock = File.join(base, 'fits.sock')
        server = build_test_server(socket_path: sock)
        server.start
        begin
          expect { server.start }.to raise_error(/already running/)
        ensure
          server.stop
        end
      end
    end
  end
```

If the spec file has no `build_test_server` helper, add one near the top that builds a `SocketServer` with a stubbed handler/metrics and a `Config`-like double whose `socket_path`, `queue_capacity`, `log_level`, `read_timeout`, `write_timeout` return test values. Reuse whatever double the file already defines rather than duplicating it.

- [ ] **Step 3: Run tests to verify they fail**

Run: `bundle exec rspec spec/socket_server_spec.rb -e start`
Expected: FAIL — dir not created (parent may not exist → `UNIXServer.new` raises) and double-start does not raise.

- [ ] **Step 4: Implement in `start`**

Edit `lib/fits_jruby/socket_server.rb` `start` (lines 47-60) to guard and create the dir:

```ruby
    def start
      raise 'server already running' if @running.get

      ensure_socket_dir
      remove_stale_socket
      @server = UNIXServer.new(socket_path)
      # Enforce 0660 in code rather than relying on the ambient umask, so a
      # permissive umask cannot yield a world-connectable socket. Group
      # ownership comes from the process's gid; we deliberately do not chown
      # (uid/gid mapping is deployment-specific).
      File.chmod(0o660, socket_path)
      @running.set(true)
      @stopped = false
      @worker = Thread.new { worker_loop }
      @acceptor = Thread.new { acceptor_loop }
      @logger.info("ready: listening on #{socket_path} (queue capacity #{@config.queue_capacity})")
    end
```

Add this private helper (near `remove_stale_socket`):

```ruby
    # Create the socket's parent directory 0700 if it does not exist. The
    # default socket path lives under a per-user runtime dir (see Config); in
    # the XDG or systemd case the dir already exists and this is a no-op.
    def ensure_socket_dir
      FileUtils.mkdir_p(File.dirname(socket_path), mode: 0o700)
    end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/socket_server_spec.rb`
Expected: PASS (all socket_server examples).

- [ ] **Step 6: Verify RuboCop on the touched files**

Run: `bundle exec rubocop lib/fits_jruby/socket_server.rb lib/fits_jruby/config.rb`
Expected: no offenses. If `Metrics/ClassLength` trips, bump `Max` in `.rubocop.yml` by the measured amount and update its comment to state why (honest ceiling).

- [ ] **Step 7: Commit**

```bash
git add lib/fits_jruby/socket_server.rb spec/socket_server_spec.rb .rubocop.yml
git commit -m "feat: create socket parent dir 0700 and guard double-start

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: FitsInstaller refuses non-https redirects

**Files:**
- Modify: `lib/fits_jruby/fits_installer.rb:44-55` (`handle_response`)
- Test: `spec/fits_installer_spec.rb` (new example; create the file if it does not exist)

**Interfaces:**
- Consumes: `Net::HTTPRedirection#['location']`, `URI`.
- Produces: `FitsInstaller.handle_response` raises `FitsInstaller::Error` ("refusing insecure redirect ...") when a redirect's `location` scheme is not `https`.

- [ ] **Step 1: Check for an existing installer spec**

Run: `ls spec/fits_installer_spec.rb 2>/dev/null && head -30 spec/fits_installer_spec.rb || echo "no installer spec"`
If it exists, add to it; otherwise create it following the pattern of other specs (a `describe FitsJruby::FitsInstaller`).

- [ ] **Step 2: Write the failing test**

The cleanest seam is the class method `handle_response`, which takes a response object. Add to `spec/fits_installer_spec.rb`:

```ruby
# frozen_string_literal: true

require 'fits_jruby/fits_installer'

RSpec.describe FitsJruby::FitsInstaller do
  describe '.handle_response' do
    it 'refuses a redirect to a non-https location' do
      response = Net::HTTPRedirection.allocate
      def response.[](key)
        key == 'location' ? 'http://evil.example/fits.zip' : nil
      end

      expect do
        described_class.handle_response(response, 'https://orig.example/fits.zip', '/tmp/x.zip', 3)
      end.to raise_error(FitsJruby::FitsInstaller::Error, /insecure redirect/)
    end
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bundle exec rspec spec/fits_installer_spec.rb -e 'insecure redirect'`
Expected: FAIL — current code follows the http redirect (attempts a fetch) instead of raising.

- [ ] **Step 4: Implement the https guard**

Edit `lib/fits_jruby/fits_installer.rb` `handle_response` (lines 44-55). In the `when Net::HTTPRedirection` branch, reject a non-https location before recursing:

```ruby
    def self.handle_response(response, url, dest, redirects_left)
      case response
      when Net::HTTPRedirection
        raise Error, "too many redirects (>#{MAX_REDIRECTS}) fetching FITS" if redirects_left <= 0

        location = response['location']
        unless URI(location).scheme == 'https'
          raise Error, "refusing insecure redirect to #{location} (expected https)"
        end

        fetch_to_file(location, dest, redirects_left - 1)
      when Net::HTTPSuccess
        File.open(dest, 'wb') { |f| response.read_body { |chunk| f.write(chunk) } }
      else
        raise Error, "download failed: HTTP #{response.code} for #{url}"
      end
    end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bundle exec rspec spec/fits_installer_spec.rb`
Expected: PASS.

- [ ] **Step 6: RuboCop the touched file**

Run: `bundle exec rubocop lib/fits_jruby/fits_installer.rb`
Expected: no offenses (the `unless ... raise` guard fits within MethodLength; if `Style/GuardClause` or line length complains, keep the guard as a single-line `raise Error, ... unless URI(location).scheme == 'https'` under 120 cols).

- [ ] **Step 7: Commit**

```bash
git add lib/fits_jruby/fits_installer.rb spec/fits_installer_spec.rb
git commit -m "feat: refuse non-https redirects in FITS installer

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Convenience API — build_server + run!

**Files:**
- Modify: `lib/fits_jruby.rb` (add module methods)
- Modify: `bin/fits-server` (collapse onto `run!`)
- Test: `spec/fits_jruby_spec.rb` (create)

**Interfaces:**
- Consumes: `Config` (`#validate!`, `#fits_home`, `#allowed_roots`, `#log_level`), `Metrics.new`, `FitsExaminer.new(fits_home)`, `RequestHandler.new(examiner:, metrics:, allowed_roots:)`, `SocketServer.new(config:, handler:, metrics:)`.
- Produces:
  - `FitsJruby.build_server(config: Config.new)` → a `SocketServer`. Pure assembly; no validation, no signal traps, no `sleep`.
  - `FitsJruby.run!(config: Config.new)` → validates (converting `Config::Error` to `warn` + `exit 1`), builds, installs INT/TERM traps (`server.stop` then `exit 0`), `server.start`, `sleep`. Never returns normally.

- [ ] **Step 1: Write the failing test for build_server**

`build_server` constructs a real `FitsExaminer`, which loads the JVM/FITS — too heavy for a fast unit test. Make the examiner injectable so the wiring is testable without FITS. Create `spec/fits_jruby_spec.rb`:

```ruby
# frozen_string_literal: true

require 'fits_jruby'

RSpec.describe FitsJruby do
  describe '.build_server' do
    it 'wires a SocketServer with a handler confined to config.allowed_roots' do
      Dir.mktmpdir do |root|
        config = instance_double(
          FitsJruby::Config,
          fits_home: '/does/not/matter',
          allowed_roots: [root],
          socket_path: "#{root}/fits.sock",
          queue_capacity: 64,
          log_level: :error,
          read_timeout: 5,
          write_timeout: 30
        )
        fake_examiner = instance_double(FitsJruby::FitsExaminer)

        server = described_class.build_server(config: config, examiner: fake_examiner)

        expect(server).to be_a(FitsJruby::SocketServer)
        expect(server.socket_path).to eq("#{root}/fits.sock")
      end
    end
  end
end
```

Add `require 'tmpdir'` at the top of the spec.

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/fits_jruby_spec.rb`
Expected: FAIL — `FitsJruby.build_server` is undefined.

- [ ] **Step 3: Implement build_server and run!**

Replace `lib/fits_jruby.rb` with:

```ruby
# frozen_string_literal: true

require_relative 'fits_jruby/config'
require_relative 'fits_jruby/metrics'
require_relative 'fits_jruby/request_handler'
require_relative 'fits_jruby/fits_examiner'
require_relative 'fits_jruby/socket_server'

module FitsJruby
  # Assemble the server object graph and return the SocketServer. Pure
  # assembly: no config validation, no signal traps, no blocking. The examiner
  # is injectable so the wiring can be unit-tested without loading FITS/JVM.
  def self.build_server(config: Config.new, examiner: nil)
    examiner ||= FitsExaminer.new(config.fits_home)
    metrics = Metrics.new
    handler = RequestHandler.new(
      examiner: examiner,
      metrics: metrics,
      allowed_roots: config.allowed_roots
    )
    SocketServer.new(config: config, handler: handler, metrics: metrics)
  end

  # Entry point used by bin/fits-server: validate config, build the server,
  # install INT/TERM handlers for a clean shutdown, start, and block forever.
  # Never returns under normal operation.
  def self.run!(config: Config.new)
    config.validate!
    server = build_server(config: config)
    install_signal_traps(server)
    server.start
    sleep
  rescue Config::Error => e
    warn "configuration error: #{e.message}"
    exit 1
  end

  def self.install_signal_traps(server)
    shutdown = proc do
      server.stop
      exit 0
    end
    Signal.trap('INT', &shutdown)
    Signal.trap('TERM', &shutdown)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/fits_jruby_spec.rb`
Expected: PASS.

- [ ] **Step 5: Collapse bin/fits-server onto run!**

Replace `bin/fits-server` with:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'fits_jruby'

FitsJruby.run!
```

- [ ] **Step 6: Verify the binary still boots (integration-style manual check)**

Run: `FITS_HOME=~/tools/fits-1.6.0 timeout 25 bundle exec ruby bin/fits-server 2>&1 | head -5`
Expected: within a few seconds, a line containing `ready: listening on` and a `fits.sock` path; `timeout` then kills it. If FITS is not installed, expect `configuration error: FITS_HOME ...` instead — that also confirms `run!`'s validation path works.

- [ ] **Step 7: Run the full fast suite + RuboCop**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: all fast examples PASS; RuboCop clean across all files.

- [ ] **Step 8: Commit**

```bash
git add lib/fits_jruby.rb bin/fits-server spec/fits_jruby_spec.rb
git commit -m "feat: add FitsJruby.build_server and run! convenience API

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: perf micro-hygiene (safe, no behavior change)

**Files:**
- Modify: `lib/fits_jruby/request_handler.rb` and/or `lib/fits_jruby/socket_server.rb` (only if a clearly-safe win exists)

**Interfaces:**
- Consumes: nothing new.
- Produces: no behavior change; identical outputs.

- [ ] **Step 1: Identify a concrete, safe win**

Read the hot path (`RequestHandler#handle`, `SocketServer#log_request`). The one concrete redundancy: `handle` computes `request = raw_request.to_s.strip`, and `log_request` recomputes `raw.to_s.strip` for the STATS comparison. These are on different objects (handler vs server) so they cannot share a variable without changing signatures — do NOT refactor across the boundary just to save a strip. If no genuinely safe, self-contained win exists, SKIP this task and note it in the commit-less summary. Only proceed to Step 2 if there is a real, local improvement.

- [ ] **Step 2: If a safe win exists, write/adjust a test proving behavior is unchanged**

Confirm existing `spec/request_handler_spec.rb` covers `handle` for STATS, empty, and a valid path. If coverage is missing for the exact path you touch, add an assertion first. Run: `bundle exec rspec spec/request_handler_spec.rb` — Expected: PASS before and after.

- [ ] **Step 3: Apply the change and re-run**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: PASS + clean.

- [ ] **Step 4: Commit (only if a change was made)**

```bash
git add -A
git commit -m "perf: minor hot-path hygiene (no behavior change)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

If no safe win was found, make NO commit and record "perf micro-hygiene: reviewed, no safe self-contained change; skipped" in the task report.

---

### Task 7: Documentation updates

**Files:**
- Modify: `DEPLOYMENT.md`, `INSTALL.md`, `README.md`

**Interfaces:**
- Consumes: the new socket default (Task 2) and per-user runtime dir semantics.
- Produces: docs consistent with code.

- [ ] **Step 1: DEPLOYMENT.md — rename service-account examples**

In `DEPLOYMENT.md`, rename the OS service-account username examples:
- Line ~46-47: "Add the application's service user (e.g. `sidekiq` or `rails`)" → "(e.g. `avi` or `deployer`)".
- Line ~50: `sudo usermod -aG fits sidekiq` → `sudo usermod -aG fits deployer`.

Do NOT change "multiple Sidekiq threads" in the Concurrency section (line ~348) — that names the client framework, not an OS account.

- [ ] **Step 2: DEPLOYMENT.md — add /usr/local/tools FITS_HOME alternative**

At the Prerequisites bullet (line ~15) "FITS 1.6.0 unzipped to a stable location, e.g. `/opt/fits-1.6.0`." append ` (or \`/usr/local/tools/fits-1.6.0\`)`. Leave the `Environment=FITS_HOME=/opt/fits-1.6.0` and `ReadOnlyPaths=` unit examples as the primary path (adding a comment is optional; keep the unit file coherent with one path).

- [ ] **Step 3: INSTALL.md — add /usr/local/tools FITS_HOME alternative**

In `INSTALL.md` Step 3 (line ~85) and Step 5 (line ~155), where `~/tools/fits-1.6.0` appears as the example, add a note that `/usr/local/tools/fits-1.6.0` is an alternative for a shared/system install, e.g. after line 86 add:

```markdown
> A shared, system-wide alternative is `/usr/local/tools/fits-1.6.0`; use that
> in place of `~/tools/fits-1.6.0` below if you prefer a system location.
```

- [ ] **Step 4: README.md — update socket default + examples**

In `README.md`:
- Quick start note (line ~22): "listens on `/tmp/fits.sock` by default" → describe the new default: "listens on a per-user socket by default (`$XDG_RUNTIME_DIR/fits.sock`, or `<tmpdir>/fits-<uid>/fits.sock` when `XDG_RUNTIME_DIR` is unset)".
- Env var table `FITS_SOCKET_PATH` row (line ~30): change default cell from `/tmp/fits.sock` to `per-user *(see below)*` and update the description to explain the XDG/tmpdir fallback and that the parent dir is created `0700`.
- Protocol command examples using `/tmp/fits.sock` (lines ~162-189): these are illustrative client commands. Update them to a neutral placeholder `"$FITS_SOCKET"` with a one-line note, OR keep `/tmp/fits.sock` but add a note that the actual path depends on the default above. Prefer introducing `FITS_SOCKET=/path/to/fits.sock` once and using `"$FITS_SOCKET"` in the examples for correctness.

- [ ] **Step 5: Grep for any remaining stale /tmp/fits.sock default claims**

Run: `grep -rn '/tmp/fits.sock' README.md INSTALL.md DEPLOYMENT.md`
Expected: any remaining hits are clearly illustrative client-command paths with a nearby note, not a statement that `/tmp/fits.sock` is *the default*. Fix any that still assert it as the default.

- [ ] **Step 6: Commit**

```bash
git add README.md INSTALL.md DEPLOYMENT.md
git commit -m "docs: rename service accounts, add /usr/local/tools, update socket default

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: Final verification

- [ ] **Step 1: Full fast suite**

Run: `bundle exec rspec`
Expected: all fast examples green (86 prior + new).

- [ ] **Step 2: Integration suite (if FITS present)**

Run: `FITS_HOME=~/tools/fits-1.6.0 bundle exec rspec --tag integration`
Expected: 4 integration examples green (or clean skip if FITS absent).

- [ ] **Step 3: RuboCop + audit**

Run: `bundle exec rubocop && bundle exec rake audit`
Expected: no offenses; bundler-audit reports no vulnerabilities.

- [ ] **Step 4: Smoke test**

Run: `rake smoke`
Expected: PASS, or clean exit 0 if FITS not installed.

---

## Self-Review Notes

- **Spec coverage:** convenience API (Task 5), all four Lows — `/tmp` default (Task 2 + dir creation in Task 3), https redirects (Task 4), start/stop guard (Task 3), perf hygiene (Task 6); docs (Task 7); Gemfile (Task 1). All spec sections mapped.
- **Type consistency:** `build_server(config:, examiner:)` and `run!(config:)` signatures are used consistently; `handle_response(response, url, dest, redirects_left)` matches the existing 4-arg signature.
- **Known test edit:** `spec/config_spec.rb:25-30` asserts the old `/tmp/fits.sock` default and MUST be updated in Task 2 Step 1 (called out explicitly).
