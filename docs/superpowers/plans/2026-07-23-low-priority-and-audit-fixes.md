# Low-Priority & Audit Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the remaining Low-priority audit findings plus the newly-found security/performance/correctness bugs on the changed surface, add a `client_disconnects` metric, and realign the deployment/install docs with the code and the production per-user-RVM model.

**Architecture:** Six sequential tasks on branch `feature/low-priority-and-audit` (off `main` @ 14ca4c6). Tasks are ordered correctness/security → robustness → observability → installer → docs, so docs land last and reference the shipped metric/contract names. No wire-protocol, serial-worker, or allowlist-semantics change.

**Tech Stack:** JRuby 9.4.15.0 (Ruby 3.1.7 compat) on OpenJDK 17; RSpec (fast unit default, `:integration`-tagged); RuboCop (`rake lint`); bundler-audit (`rake audit`). FITS 1.6.0 loaded in-process.

**Spec:** docs/superpowers/specs/2026-07-23-low-priority-and-audit-fixes-design.md

## Global Constraints

- **JRuby only** (jruby-9.4.15.0, Ruby 3.1.7 compat, OpenJDK 17). Lightweight; **no new runtime dependencies** (`logger`, `json`, `net/http`, `digest` are stdlib and already used).
- **TDD mandatory.** Every behavioral change lands with a test proven RED on old code, GREEN on new. Fast unit specs default; integration is `:integration`-tagged.
- **No wire-protocol / semantics drift.** Success response starts `<?xml`; every failure is an `ERROR: …` line. `record_outcome` counts `<?xml`→success, `ERROR:`→error, anything else (STATS JSON) uncounted. Every new error string MUST start `ERROR:`.
- **`rake lint` and `rake audit` stay clean.**
- Commit trailer EXACTLY: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Claude creates local commits/branches only — never push, never configure remotes.
- Reviewers are **opus**; implementers sonnet-floor by complexity; final whole-branch review opus.
- Documentation-only (NO code): L3, NEW-2, L9 — an "Operational trade-offs" note, added in Task 6.

---

### Task 1: NEW-1 (NUL-path fail-closed) + L10 (deterministic byte-cap)

**Files:**
- Modify: `lib/fits_jruby/request_handler.rb` (`stat_check`, `resolve_target` rescue)
- Modify: `lib/fits_jruby/connection_reader.rb:37,46` (`read_line` size logic + class doc)
- Test: `spec/request_handler_spec.rb`, `spec/connection_reader_spec.rb`

**Interfaces:**
- Consumes: nothing new.
- Produces: no signature change. `RequestHandler#handle` never raises `ArgumentError` for a NUL path (returns `ERROR: path not allowed: <path>`). `ConnectionReader#read_line` contract becomes: a line incl. its trailing newline may be at most `@max_bytes` bytes; `@max_bytes` bytes with no newline raises `RequestTooLong` — deterministic regardless of chunking.

- [ ] **Step 1: Write the failing tests (NEW-1)**

Add to `spec/request_handler_spec.rb` (inside the existing top-level `describe FitsJruby::RequestHandler`):

```ruby
  describe 'NUL-byte paths (NEW-1)' do
    let(:metrics) { instance_double(FitsJruby::Metrics) }
    let(:examiner) { double('examiner') }

    it 'fails closed with a structured error when an allowlist is configured' do
      Dir.mktmpdir do |root|
        handler = described_class.new(examiner: examiner, metrics: metrics, allowed_roots: [root])
        expect { @result = handler.handle("#{root}/x\x00/etc/passwd") }.not_to raise_error
        expect(@result).to start_with('ERROR: path not allowed:')
      end
    end

    it 'never raises for a NUL path even with no allowlist' do
      handler = described_class.new(examiner: examiner, metrics: metrics)
      expect { handler.handle("/tmp/x\x00y") }.not_to raise_error
    end
  end
```

- [ ] **Step 2: Run to verify NEW-1 tests fail**

Run: `bundle exec rspec spec/request_handler_spec.rb -e "NUL-byte"`
Expected: FAIL — with an allowlist, `File.exist?` raises `ArgumentError: string contains null byte` out of `handle` (the `rescue SystemCallError` does not catch it).

- [ ] **Step 3: Implement NEW-1**

In `lib/fits_jruby/request_handler.rb`, add a NUL guard as the FIRST check in `stat_check` after the absolute-path check, and widen the `resolve_target` rescue:

```ruby
    def resolve_target(path)
      stat_error = stat_check(path)
      return [nil, stat_error] if stat_error
      return [path, nil] if @allowed_roots.empty?

      real = File.realpath(path)
      return [nil, "ERROR: path not allowed: #{path}"] unless @allowed_roots.any? { |root| under_root?(real, root) }

      [real, nil]
    rescue SystemCallError, ArgumentError
      # SystemCallError: ENOENT/ELOOP/EACCES/... → not allowed (fail closed).
      # ArgumentError: File.* rejecting the argument (e.g. embedded NUL) — must
      # also fail closed rather than crash the worker.
      [nil, "ERROR: path not allowed: #{path}"]
    end

    # Returns an error string if the path fails basic file-stat checks, else nil.
    def stat_check(path)
      return "ERROR: path must be absolute: #{path}" unless path.start_with?('/')
      # Reject a NUL byte before any File.* call: File.exist?/File.file? raise
      # ArgumentError ("string contains null byte") on it, which is not a
      # SystemCallError and would otherwise escape the fail-closed rescue.
      return "ERROR: path not allowed: #{path}" if path.include?("\x00")
      return "ERROR: no such file: #{path}" unless File.exist?(path)
      return "ERROR: not a regular file: #{path}" unless File.file?(path)
      return "ERROR: not readable: #{path}" unless File.readable?(path)

      nil
    end
```

- [ ] **Step 4: Run to verify NEW-1 tests pass**

Run: `bundle exec rspec spec/request_handler_spec.rb`
Expected: PASS (new + all existing request_handler examples).

- [ ] **Step 5: Write the failing tests (L10)**

Add to `spec/connection_reader_spec.rb` (self-contained via `UNIXSocket.pair`):

```ruby
  describe 'byte cap contract (L10)' do
    def deliver(chunks, max_bytes:)
      client, server = UNIXSocket.pair
      reader = described_class.new(max_bytes: max_bytes)
      writer = Thread.new do
        chunks.each { |c| client.write(c); sleep 0.01 }
        client.close
      end
      begin
        reader.read_line(server, 2)
      ensure
        writer.join
        server.close
      end
    end

    it 'accepts a line of exactly max_bytes including the newline' do
      line = ('a' * 7) + "\n" # 8 bytes total
      expect(deliver([line], max_bytes: 8)).to eq(line)
    end

    it 'raises RequestTooLong at max_bytes with no newline' do
      expect { deliver(['a' * 8], max_bytes: 8) }
        .to raise_error(described_class::RequestTooLong)
    end

    it 'gives the same result regardless of how an over-length input is chunked' do
      # 12 bytes, no newline, cap 8 → RequestTooLong either way.
      whole = 'a' * 12
      split = ['a' * 5, 'a' * 7]
      expect { deliver([whole], max_bytes: 8) }.to raise_error(described_class::RequestTooLong)
      expect { deliver(split, max_bytes: 8) }.to raise_error(described_class::RequestTooLong)
    end
  end
```

- [ ] **Step 6: Run to verify L10 tests fail**

Run: `bundle exec rspec spec/connection_reader_spec.rb -e "byte cap contract"`
Expected: FAIL — the exact-`max_bytes` accept case and/or the chunk-independence case fail because the current `+ 1` read size and post-newline size check let the buffer reach `max_bytes + 1` and behave differently across chunk splits.

- [ ] **Step 7: Implement L10**

In `lib/fits_jruby/connection_reader.rb`, drop the `+ 1` and update the doc so the buffer never exceeds `@max_bytes`:

```ruby
    # Read a newline-terminated request line with a timeout and size cap.
    # Contract: a line INCLUDING its trailing newline may be at most @max_bytes
    # bytes. Returns the line (including the trailing newline), nil on EOF/close,
    # raises ReadTimeout on timeout, raises RequestTooLong when @max_bytes bytes
    # accumulate without a newline. Deterministic regardless of how the peer
    # chunks its writes.
    def read_line(connection, timeout) # rubocop:disable Metrics/AbcSize
      buf = +''
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

      loop do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise ReadTimeout if remaining <= 0

        raise ReadTimeout unless connection.wait_readable(remaining)

        # Never read past @max_bytes: when buf is full the size check below fires
        # before we would ever request 0 bytes.
        chunk = connection.read_nonblock(@max_bytes - buf.length, exception: false)
        next if chunk == :wait_readable # shouldn't happen after wait_readable, but be safe

        return nil if chunk.nil? # EOF

        buf << chunk
        newline_idx = buf.index("\n")
        return buf[0..newline_idx] if newline_idx

        raise RequestTooLong if buf.length >= @max_bytes
      end
    end
```

Also update the `DEFAULT_MAX_BYTES` / class-level comment block only if it states the old contract (the class doc at the top already describes "maximum byte count" — leave unless it contradicts).

- [ ] **Step 8: Run to verify L10 tests pass + full reader suite**

Run: `bundle exec rspec spec/connection_reader_spec.rb`
Expected: PASS (new + existing). Confirm no existing timeout/EOF example regressed.

- [ ] **Step 9: Full fast suite + lint**

Run: `bundle exec rspec && rake lint`
Expected: all fast specs PASS; RuboCop clean.

- [ ] **Step 10: Commit**

```bash
git add lib/fits_jruby/request_handler.rb lib/fits_jruby/connection_reader.rb \
        spec/request_handler_spec.rb spec/connection_reader_spec.rb
git commit -m "fix: fail closed on NUL-byte paths (NEW-1) and make the request byte cap deterministic (L10)

NEW-1: File.exist? raises ArgumentError (not SystemCallError) on a NUL-byte
path, escaping the fail-closed rescue and crashing the worker. Reject NUL in
stat_check before any File.* call and widen resolve_target's rescue to
ArgumentError.

L10: the +1 read size plus a post-newline size check let the buffer reach
max_bytes+1 and made accept/reject depend on chunk timing. Read at most
max_bytes-buf.length so a line incl. newline is capped at max_bytes exactly,
deterministically.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: L6 (generic examine error + server-side logging) + L7 (STATS-unavailable contract)

**Files:**
- Modify: `lib/fits_jruby/request_handler.rb` (add `logger:`; `examine`; new `stats_response`)
- Modify: `lib/fits_jruby.rb` (`build_server` builds one logger, injects into handler + server; new `build_logger`)
- Test: `spec/request_handler_spec.rb`, `spec/fits_jruby_spec.rb`

**Interfaces:**
- Consumes: an optional `logger:` (any object responding to `error`); defaults to a null sink so existing callers/specs are unaffected.
- Produces: `RequestHandler.new(examiner:, metrics:, allowed_roots: [], logger: nil)`. On examiner failure `handle` returns exactly `ERROR: examination failed` (no internal detail) and logs class+message+backtrace. On a `snapshot` failure `handle("STATS")` returns `ERROR: stats unavailable` and logs the cause. `FitsJruby.build_logger(level)` returns a `$stdout` Logger at the given level.

- [ ] **Step 1: Write the failing tests**

Add to `spec/request_handler_spec.rb`:

```ruby
  describe 'error containment (L6/L7)' do
    let(:metrics) { instance_double(FitsJruby::Metrics) }
    let(:log_io) { StringIO.new }
    let(:logger) { Logger.new(log_io) }

    it 'returns a generic examine error and logs the detail server-side (L6)' do
      examiner = double('examiner')
      allow(examiner).to receive(:examine).and_raise(RuntimeError, 'secret /internal/path detail')
      handler = described_class.new(examiner: examiner, metrics: metrics, logger: logger)

      result = handler.handle('/etc/hostname')

      expect(result).to eq('ERROR: examination failed')
      expect(result).not_to include('secret')
      expect(log_io.string).to include('RuntimeError').and include('secret /internal/path detail')
    end

    it 'returns ERROR: stats unavailable when snapshot fails and logs the cause (L7)' do
      allow(metrics).to receive(:snapshot).and_raise(StandardError, 'heap bean exploded')
      handler = described_class.new(examiner: double('examiner'), metrics: metrics, logger: logger)

      result = handler.handle('STATS')

      expect(result).to eq('ERROR: stats unavailable')
      expect(log_io.string).to include('heap bean exploded')
    end

    it 'still returns the JSON snapshot when STATS succeeds' do
      allow(metrics).to receive(:snapshot).and_return({ requests_total: 3 })
      handler = described_class.new(examiner: double('examiner'), metrics: metrics, logger: logger)
      expect(handler.handle('STATS')).to eq('{"requests_total":3}')
    end
  end
```

(Ensure `require 'stringio'` and `require 'logger'` are available in the spec — add to the file head if not already loaded via `spec_helper`.)

Add to `spec/fits_jruby_spec.rb`:

```ruby
  describe '.build_server logger wiring (L6)' do
    it 'injects a shared Logger into the RequestHandler' do
      Dir.mktmpdir do |home|
        FileUtils.mkdir_p(File.join(home, 'lib'))
        config = FitsJruby::Config.new('FITS_HOME' => home, 'XDG_RUNTIME_DIR' => nil)
        expect(FitsJruby::RequestHandler).to receive(:new)
          .with(hash_including(logger: kind_of(Logger))).and_call_original
        FitsJruby.build_server(config: config, examiner: double('examiner'))
      end
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/request_handler_spec.rb -e "error containment" spec/fits_jruby_spec.rb -e "logger wiring"`
Expected: FAIL — `RequestHandler.new` rejects `logger:` (ArgumentError), `examine` currently returns `ERROR: examination failed: <msg>` and does not log, and `handle('STATS')` propagates a raising snapshot.

- [ ] **Step 3: Implement L6 + L7 in request_handler.rb**

At the top of `lib/fits_jruby/request_handler.rb` add `require 'logger'` (below `require 'json'`). Then:

```ruby
    def initialize(examiner:, metrics:, allowed_roots: [], logger: nil)
      @examiner = examiner
      @metrics = metrics
      # Null sink by default so existing callers/tests are unaffected; the server
      # injects a real logger via FitsJruby.build_server.
      @logger = logger || Logger.new(File::NULL)
      # Canonicalize configured roots once so the boundary check compares
      # realpath-to-realpath. An empty list means no confinement (default).
      @allowed_roots = allowed_roots.map { |root| File.realpath(root) }
    end

    def handle(raw_request)
      request = raw_request.to_s.strip
      return stats_response if request == STATS_COMMAND
      return 'ERROR: empty request' if request.empty?

      target, error = resolve_target(request)
      return error if error

      examine(target)
    end
```

Add (private) a guarded STATS responder and update `examine`:

```ruby
    # STATS with a defined failure contract: if the snapshot or its
    # serialization fails, return a stable error line and log the cause rather
    # than crashing the worker and leaving the client with no response (L7).
    def stats_response
      @metrics.snapshot.to_json
    rescue StandardError => e
      @logger.error("stats snapshot failed: #{e.class}: #{e.message}")
      'ERROR: stats unavailable'
    end

    def examine(path)
      @examiner.examine(path)
    rescue StandardError => e
      # Do NOT leak internal detail to the client; log it server-side (L6).
      @logger.error("examination failed for #{path}: #{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}")
      'ERROR: examination failed'
    end
```

- [ ] **Step 4: Implement the logger wiring in fits_jruby.rb**

In `lib/fits_jruby.rb` add `require 'logger'` at the top, then build one logger and inject it into both the handler and the server:

```ruby
  def self.build_server(config: Config.new, examiner: nil)
    examiner ||= FitsExaminer.new(config.fits_home)
    metrics = Metrics.new
    logger = build_logger(config.log_level)
    handler = RequestHandler.new(
      examiner: examiner,
      metrics: metrics,
      allowed_roots: config.allowed_roots,
      logger: logger
    )
    SocketServer.new(config: config, handler: handler, metrics: metrics, logger: logger)
  end

  # Build the shared server logger. SocketServer keeps its own equivalent
  # fallback for direct construction (e.g. specs) when no logger is injected;
  # the small overlap is intentional so neither construction path can produce a
  # nil logger.
  def self.build_logger(level)
    logger = Logger.new($stdout)
    logger.level = Logger.const_get(level.to_s.upcase)
    logger
  end
```

- [ ] **Step 5: Run to verify they pass**

Run: `bundle exec rspec spec/request_handler_spec.rb spec/fits_jruby_spec.rb`
Expected: PASS. Update any pre-existing example asserting the old `examination failed: <msg>` string to expect `ERROR: examination failed`.

- [ ] **Step 6: Full fast suite + lint**

Run: `bundle exec rspec && rake lint`
Expected: all fast specs PASS; RuboCop clean.

- [ ] **Step 7: Commit**

```bash
git add lib/fits_jruby/request_handler.rb lib/fits_jruby.rb \
        spec/request_handler_spec.rb spec/fits_jruby_spec.rb
git commit -m "fix: contain examine/STATS errors server-side (L6, L7)

L6: examine returned the raw internal exception message to the client and
logged nothing. Return a generic 'ERROR: examination failed' and log
class/message/backtrace via an injected logger (null sink by default).

L7: a raising metrics snapshot crashed the worker with no client response.
Guard the STATS branch to return 'ERROR: stats unavailable' and log the cause.

build_server now builds one logger and injects it into both the handler and
the server.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: NEW-3 (no full-response copy) + NEW-4 (inspect in log) + L5 (bounded read-error write)

**Files:**
- Modify: `lib/fits_jruby/socket_server.rb` (`write_response`/new `write_all`, `write_read_error`, `log_request`)
- Test: `spec/socket_server_spec.rb`

**Interfaces:**
- Consumes: `@config.write_timeout`.
- Produces: no public signature change. New private `write_all(connection, message)` → `:ok` or `:timeout`, letting `Errno::EPIPE`/`ECONNRESET` propagate. `write_response` keeps its exact current metric behavior (records error only on `:timeout`; silent `false` on peer-close). `write_read_error` is now bounded (non-blocking, deadline-limited) and records `record_error` **exactly once** via `ensure`. `log_request` logs `request.inspect`.

**INVARIANT the reviewer must verify:** a read-timeout / request-too-long response increments `record_error` exactly once whether the client reads, times out, or disconnects — never twice, never zero.

- [ ] **Step 1: Write the failing tests**

Add to `spec/socket_server_spec.rb`. These use `UNIXSocket.pair` directly against the private methods; adjust to the file's existing helper style if one already wraps `send`:

```ruby
  describe 'write path (NEW-3/NEW-4/L5)' do
    let(:metrics) { FitsJruby::Metrics.new(heap_reader: -> { { used: 1, max: 2 } }) }

    def build_bare_server(write_timeout: 30)
      config = FitsJruby::Config.new('FITS_HOME' => '/unused', 'XDG_RUNTIME_DIR' => nil,
                                     'FITS_WRITE_TIMEOUT' => write_timeout.to_s)
      handler = FitsJruby::RequestHandler.new(examiner: FakeExaminer.new, metrics: metrics)
      FitsJruby::SocketServer.new(config: config, handler: handler, metrics: metrics,
                                  logger: Logger.new(File::NULL))
    end

    it 'writes the original response object without copying when it fits (NEW-3)' do
      server = build_bare_server
      client, sock = UNIXSocket.pair
      response = "#{'<?xml ' * 10}\n"
      expect(sock).to receive(:write_nonblock).once.and_wrap_original do |m, chunk, **kw|
        expect(chunk).to equal(response) # same object, not a byteslice copy
        m.call(chunk, **kw)
      end
      expect(server.send(:write_response, sock, response)).to be(true)
      expect(client.read(response.bytesize)).to eq(response)
    ensure
      client.close; sock.close
    end

    it 'logs the request with control chars escaped (NEW-4)' do
      log_io = StringIO.new
      config = FitsJruby::Config.new('FITS_HOME' => '/unused', 'XDG_RUNTIME_DIR' => nil)
      handler = FitsJruby::RequestHandler.new(examiner: FakeExaminer.new, metrics: metrics)
      server = FitsJruby::SocketServer.new(config: config, handler: handler, metrics: metrics,
                                           logger: Logger.new(log_io))
      server.send(:log_request, "/tmp/a\tb\n", '<?xml ...', Process.clock_gettime(Process::CLOCK_MONOTONIC))
      expect(log_io.string).to include('\t') # escaped form present
      expect(log_io.string).not_to include("\t") # raw tab absent
    end

    it 'bounds write_read_error and records the error exactly once when the client reads (L5)' do
      server = build_bare_server
      client, sock = UNIXSocket.pair
      expect { server.send(:write_read_error, sock, 'ERROR: read timeout') }
        .to change { metrics.snapshot[:requests_error] }.by(1)
      expect(client.read(20)).to eq('ERROR: read timeout')
    ensure
      client.close; sock.close
    end

    it 'does not block on a non-reading client and records the error once (L5)' do
      server = build_bare_server(write_timeout: 1)
      _client, sock = UNIXSocket.pair # peer never reads
      big = 'ERROR: ' + ('x' * 5_000_000)
      # Stub write_nonblock to never make progress so the deadline is what ends it.
      allow(sock).to receive(:write_nonblock).and_return(:wait_writable)
      allow(sock).to receive(:wait_writable).and_return(nil)
      result = nil
      thread = Thread.new { result = server.send(:write_read_error, sock, big) }
      expect(thread.join(5)).not_to be_nil # returned within the bounded time, did not hang
      expect(metrics.snapshot[:requests_error]).to eq(1)
    ensure
      _client.close; sock.close
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/socket_server_spec.rb -e "write path"`
Expected: FAIL — NEW-3 (first `write_nonblock` receives a byteslice copy, not the same object), NEW-4 (`log_request` interpolates the raw tab), L5 (`write_read_error` uses a blocking `write` — the non-reading-client example hangs/does not bound; and on JRuby the blocking write can raise rather than record once).

- [ ] **Step 3: Implement NEW-3 + L5 (extract `write_all`)**

In `lib/fits_jruby/socket_server.rb`, replace `write_read_error` and `write_response` with a shared bounded writer plus thin wrappers:

```ruby
    # Bounded, non-blocking write of the whole message using a monotonic
    # deadline. Returns :ok when fully written or :timeout when the write
    # deadline elapses. Lets Errno::EPIPE/ECONNRESET propagate to the caller so
    # each caller can decide how a peer-close is counted. Writes the original
    # string on the first pass (offset 0) so a response that fits in one write
    # is never copied (NEW-3).
    def write_all(connection, message)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @config.write_timeout
      offset   = 0
      total    = message.bytesize

      while offset < total
        chunk   = offset.zero? ? message : message.byteslice(offset, total - offset)
        written = connection.write_nonblock(chunk, exception: false)
        if written == :wait_writable
          time_left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return :timeout if time_left <= 0 || connection.wait_writable(time_left).nil?
        else
          offset += written
        end
      end
      :ok
    end

    # Write the full success response. Returns true on success, false if the
    # write timed out or the peer closed. Preserves the prior metric behavior:
    # a write timeout is recorded as an error here (record_outcome is skipped by
    # serve on a false return); a peer-close mid-write is not alarmed on.
    #
    # NOTE: JRuby raises Errno::EPIPE from write_nonblock even with
    # exception: false when the peer closes; we rescue it here.
    def write_response(connection, response)
      case write_all(connection, response)
      when :ok
        true
      else # :timeout
        @logger.warn('write timeout for client; abandoning connection')
        @metrics.record_error
        false
      end
    rescue Errno::EPIPE, Errno::ECONNRESET
      false
    end

    # Write an early-exit error response (read timeout / request too long)
    # through the same bounded writer so a non-reading client cannot wedge the
    # worker (L5). Best-effort: the client may already be gone. The outcome is
    # an error regardless of how the write ends, so record_error fires exactly
    # once via ensure.
    def write_read_error(connection, message)
      write_all(connection, message)
    rescue IOError, Errno::EPIPE, Errno::ECONNRESET
      nil
    ensure
      @metrics.record_error
    end
```

- [ ] **Step 4: Implement NEW-4 (inspect in log)**

In `log_request`, escape the request in the info line:

```ruby
    def log_request(raw, response, started)
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      request = raw.to_s.strip
      if request == RequestHandler::STATS_COMMAND
        @logger.debug("stats request (#{duration_ms}ms)")
      else
        outcome = response.start_with?('<?xml') ? 'success' : 'error'
        @logger.info("examine path=#{request.inspect} outcome=#{outcome} duration_ms=#{duration_ms}")
      end
    end
```

- [ ] **Step 5: Run to verify they pass**

Run: `bundle exec rspec spec/socket_server_spec.rb`
Expected: PASS (new + existing). Confirm no existing `write_response`/serve example regressed — the success, partial-write, timeout→false, and peer-close→false behaviors are all preserved.

- [ ] **Step 6: Full fast suite + lint**

Run: `bundle exec rspec && rake lint`
Expected: all fast specs PASS; RuboCop clean. (If `write_all`/`write_response` trip an AbcSize/Metrics cop, add a scoped `# rubocop:disable` matching the file's existing convention.)

- [ ] **Step 7: Commit**

```bash
git add lib/fits_jruby/socket_server.rb spec/socket_server_spec.rb
git commit -m "fix: bounded read-error write, no-copy first write, escaped request log (L5, NEW-3, NEW-4)

Extract write_all: a bounded non-blocking writer that writes the original
string on the first pass (no full-response byteslice copy — NEW-3) and returns
:ok/:timeout. write_response keeps its exact metric behavior; write_read_error
now routes through write_all so a non-reading client cannot wedge the worker
(L5), recording the error exactly once via ensure. log_request logs
request.inspect so control chars cannot forge log fields (NEW-4).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: L4 — `client_disconnects` counter + serve EOF short-circuit

**Files:**
- Modify: `lib/fits_jruby/metrics.rb` (counter, `record_client_disconnect`, snapshot field)
- Modify: `lib/fits_jruby/socket_server.rb` (`serve` short-circuits on `raw.nil?`)
- Test: `spec/metrics_spec.rb`, `spec/socket_server_spec.rb`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Metrics#record_client_disconnect` (mutex-protected, monotonic); `Metrics#snapshot` gains `client_disconnects: <int>`. `serve` on EOF (`read_line` → nil) records a disconnect, logs at debug, and returns without calling `handle`/`write_response`/`record_outcome`. A genuine empty line (`"\n"`) is unchanged — still `ERROR: empty request`, counted as error.

- [ ] **Step 1: Write the failing tests**

Add to `spec/metrics_spec.rb`:

```ruby
  describe 'client_disconnects (L4)' do
    subject(:metrics) { described_class.new(heap_reader: -> { { used: 1, max: 2 } }) }

    it 'starts at zero and increments' do
      expect(metrics.snapshot[:client_disconnects]).to eq(0)
      metrics.record_client_disconnect
      metrics.record_client_disconnect
      expect(metrics.snapshot[:client_disconnects]).to eq(2)
    end

    it 'does not affect requests_error or requests_total' do
      metrics.record_client_disconnect
      snap = metrics.snapshot
      expect(snap[:requests_error]).to eq(0)
      expect(snap[:requests_total]).to eq(0)
    end
  end
```

Add to `spec/socket_server_spec.rb` (reuse the file's `build_server`/`wait_for_socket`/`FakeExaminer` helpers):

```ruby
  describe 'client disconnect accounting (L4)' do
    it 'counts a connect-then-close as a disconnect, not a request error' do
      server, metrics = build_server(FakeExaminer.new)
      server.start
      wait_for_socket
      UNIXSocket.new(@socket_path).close # connect, send nothing, close (EOF)
      # allow the worker to observe the EOF
      Timeout.timeout(5) do
        sleep 0.02 until metrics.snapshot[:client_disconnects] == 1
      end
      snap = metrics.snapshot
      expect(snap[:client_disconnects]).to eq(1)
      expect(snap[:requests_error]).to eq(0)
    ensure
      server&.stop
    end

    it 'still counts a genuine empty line as a request error' do
      server, metrics = build_server(FakeExaminer.new)
      server.start
      wait_for_socket
      sock = UNIXSocket.new(@socket_path)
      sock.write("\n")
      sock.read # read the ERROR response / EOF
      sock.close
      Timeout.timeout(5) do
        sleep 0.02 until metrics.snapshot[:requests_error] == 1
      end
      expect(metrics.snapshot[:requests_error]).to eq(1)
      expect(metrics.snapshot[:client_disconnects]).to eq(0)
    ensure
      server&.stop
    end
  end
```

(If `build_server` returns only the server, adapt to fetch metrics as the existing tests do; if `Timeout` isn't required, add `require 'timeout'` at the spec head.)

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/metrics_spec.rb -e "client_disconnects" spec/socket_server_spec.rb -e "client disconnect accounting"`
Expected: FAIL — `snapshot` has no `client_disconnects` key / no `record_client_disconnect`; and a connect-then-close currently becomes `handle("")` → `ERROR: empty request` → `requests_error == 1`, `client_disconnects` absent.

- [ ] **Step 3: Implement the metric**

In `lib/fits_jruby/metrics.rb`, add the counter (init, recorder, snapshot field):

```ruby
    def initialize(clock: self.class.default_clock, heap_reader: self.class.default_heap_reader)
      @clock = clock
      @heap_reader = heap_reader
      @started_at = @clock.call
      @mutex = Mutex.new
      @success = 0
      @error = 0
      @client_disconnects = 0
      @queue_depth = 0
      @processing = false
    end

    # A client that connected and closed without sending a request line. Benign
    # (health-check probes, aborted clients); counted separately so it does not
    # pollute the error rate (L4).
    def record_client_disconnect
      @mutex.synchronize { @client_disconnects += 1 }
    end
```

And add to the `snapshot` hash (after `requests_error`):

```ruby
          requests_error: @error,
          client_disconnects: @client_disconnects,
          queue_depth: @queue_depth,
```

- [ ] **Step 4: Implement the serve short-circuit**

In `lib/fits_jruby/socket_server.rb`, `serve`:

```ruby
    def serve(connection)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      raw = @reader.read_line(connection, @config.read_timeout)
      if raw.nil?
        # Client connected and closed without sending a request line (EOF) —
        # a benign disconnect (e.g. a health-check probe), not a request error.
        @metrics.record_client_disconnect
        @logger.debug('client disconnected before sending a request')
        return
      end

      response = @handler.handle(raw)
      return unless write_response(connection, response)

      record_outcome(response)
      log_request(raw, response, started)
    rescue ConnectionReader::ReadTimeout
      write_read_error(connection, 'ERROR: read timeout')
    rescue ConnectionReader::RequestTooLong
      write_read_error(connection, 'ERROR: request too long')
    rescue StandardError => e
      @logger.error("worker error: #{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}")
    ensure
      safe_close(connection)
    end
```

- [ ] **Step 5: Run to verify they pass**

Run: `bundle exec rspec spec/metrics_spec.rb spec/socket_server_spec.rb`
Expected: PASS (new + existing).

- [ ] **Step 6: Full fast suite + lint**

Run: `bundle exec rspec && rake lint`
Expected: all fast specs PASS; RuboCop clean.

- [ ] **Step 7: Commit**

```bash
git add lib/fits_jruby/metrics.rb lib/fits_jruby/socket_server.rb \
        spec/metrics_spec.rb spec/socket_server_spec.rb
git commit -m "fix: count bare connect/close as client_disconnects, not request errors (L4)

read_line returns nil on EOF; serve turned that into handle('') → empty
request → requests_error, polluting the error rate with benign disconnects
and health-check probes. Add a mutex-protected client_disconnects counter to
Metrics/snapshot and short-circuit serve on EOF (record disconnect, debug-log,
return). A genuine empty line is still an error.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: L11 — assert https on the initial installer URL

**Files:**
- Modify: `lib/fits_jruby/fits_installer.rb:35-42` (`fetch_to_file`)
- Test: `spec/fits_installer_spec.rb`

**Interfaces:**
- Consumes: nothing new.
- Produces: `FitsInstaller.fetch_to_file` raises `FitsInstaller::Error` (message contains `insecure URL` and `expected https`) for a non-`https` URL **before** any network call. `https` URLs proceed unchanged. Redirect handling (already https-forced) is untouched.

- [ ] **Step 1: Write the failing tests**

Add to `spec/fits_installer_spec.rb`:

```ruby
  describe '.fetch_to_file scheme enforcement (L11)' do
    it 'refuses a non-https initial URL before any network call' do
      expect(Net::HTTP).not_to receive(:start)
      expect { described_class.fetch_to_file('http://example.com/fits.zip', '/tmp/ignored') }
        .to raise_error(described_class::Error, /insecure URL.*expected https/)
    end

    it 'proceeds past the guard for an https URL' do
      # Sentinel: reaching Net::HTTP.start means the guard passed.
      allow(Net::HTTP).to receive(:start).and_raise(StopIteration)
      expect { described_class.fetch_to_file('https://example.com/fits.zip', '/tmp/ignored') }
        .to raise_error(StopIteration)
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/fits_installer_spec.rb -e "scheme enforcement"`
Expected: FAIL — the `http://` case currently calls `Net::HTTP.start` with `use_ssl: false` (no raise before the network call).

- [ ] **Step 3: Implement L11**

In `lib/fits_jruby/fits_installer.rb`, guard the initial URL in `fetch_to_file`:

```ruby
    def self.fetch_to_file(url, dest, redirects_left = MAX_REDIRECTS)
      uri = URI(url)
      raise Error, "refusing insecure URL #{url} (expected https)" unless uri.scheme == 'https'

      Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        http.request(Net::HTTP::Get.new(uri)) do |response|
          return handle_response(response, url, dest, redirects_left)
        end
      end
    end
```

(Redirects already enforce https at `handle_response`, so every recursive `fetch_to_file` call re-passes this guard harmlessly.)

- [ ] **Step 4: Run to verify they pass**

Run: `bundle exec rspec spec/fits_installer_spec.rb`
Expected: PASS (new + existing installer examples).

- [ ] **Step 5: Full fast suite + lint + audit**

Run: `bundle exec rspec && rake lint && rake audit`
Expected: all fast specs PASS; RuboCop clean; bundler-audit clean.

- [ ] **Step 6: Commit**

```bash
git add lib/fits_jruby/fits_installer.rb spec/fits_installer_spec.rb
git commit -m "fix: force https on the initial installer URL (L11)

Redirects were already https-forced, but the initial URL's scheme was only
reflected into use_ssl, never asserted. Fail closed on a non-https initial URL
before any network call (defense-in-depth atop the pinned SHA-256).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Documentation — RVM deployment alignment, STATS wording, `$TMPDIR`, operational trade-offs

**Files:**
- Modify: `DEPLOYMENT.md` (prerequisite, service-user step, `ProtectHome`, `ExecStart`, STATS table, new trade-offs subsection)
- Modify: `INSTALL.md` (Step 2 RVM option; the `$TMPDIR` socket line)
- Modify: `README.md` (STATS table)
- Verify: `CLAUDE.md` and touched code comments (no drift)

**Interfaces:** docs-only; no code, no test. The reviewer verifies cross-doc consistency (wrapper path / JRuby version / metric field names) against the shipped code from Tasks 1–5.

- [ ] **Step 1: DEPLOYMENT.md — align on per-user RVM under `/var/fits`**

Make these edits so the whole install path is internally consistent (see spec §Doc-M):

- **Prerequisite (line ~13-14):** replace the rbenv/shared-prefix bullet with:
  `- JRuby 9.4.15.0 installed via **RVM under the `fits` service user's home** (`/var/fits/.rvm/…`); see [INSTALL.md](INSTALL.md) Step 2.`
  Add RVM to the tooling prerequisites near the OpenJDK line if not implied.
- **Step 1 service user (the `useradd` block ~line 35):** change to create the home:
  ```bash
  sudo groupadd --system fits
  sudo useradd --system --create-home --home-dir /var/fits \
               --shell /usr/sbin/nologin --gid fits fits
  ```
  Add one sentence noting the trade-off: the account gains a home under `/var/fits`
  (not `/home`) to host RVM, so it is no longer strictly home-less; it still has no
  interactive login.
- **`ProtectHome` (line ~123):** change `ProtectHome=yes` → `ProtectHome=read-only`.
  Add a short note: `ProtectHome=` only governs `/home`, `/root`, `/run/user`; the
  RVM tree lives under `/var/fits`, so it is `ProtectSystem=strict` (below) that
  makes `/var/fits` readable-but-not-writable — exactly what the wrapper needs. Do
  not add `/var/fits` to `ReadWritePaths` unless a runtime write need is shown.
- **`ExecStart` (line ~103):** change to the RVM wrapper:
  `ExecStart=/var/fits/.rvm/wrappers/jruby-9.4.15.0/jruby bin/fits-server`
  Add a sentence: generate the wrapper with `rvm wrapper jruby-9.4.15.0`; it sets
  the gem environment without a login shell, so `NoNewPrivileges=yes` and the rest
  of the hardening are unaffected (no `bash -lc`/`rvm-exec` layer).
- Verify no other DEPLOYMENT line still implies a home-less user or
  `/usr/local/bin/jruby`.

- [ ] **Step 2: DEPLOYMENT.md + README.md — STATS wording + `client_disconnects`**

- Both STATS tables: correct the `requests_*` descriptions so `requests_error`
  reads as **all** error responses (protocol/validation errors AND examination
  failures), not only failed examinations. Keep `requests_total = success + error`
  and note it excludes `STATS`. Carry the "does not count `STATS`" note into
  README's table too (DEPLOYMENT already has it).
- Add a `client_disconnects` row to **both** tables:
  `| `client_disconnects` | Clients that connected and closed without sending a request (health checks, aborted clients). Not counted as errors. |`
  Confirm the field name matches `Metrics#snapshot` from Task 4 verbatim.

- [ ] **Step 3: DEPLOYMENT.md — Operational trade-offs subsection (L3 / NEW-2 / L9)**

Add a short "Operational trade-offs" subsection (docs-only, no config knobs implied):
1. **Shutdown:** an examination still running after a 5s grace is force-killed on stop (bounded, supervisor-visible).
2. **Serial worker:** one examination runs at a time by design; a large file blocks the queue for its duration, while idle/slow clients are bounded by `FITS_READ_TIMEOUT`.
3. **Installer redirects:** the build-time installer follows up to 5 https redirects, integrity-checked by the pinned SHA-256.

- [ ] **Step 4: INSTALL.md — add the RVM install path (Step 2)**

Restructure Step 2 into two labeled options, RVM first (see spec §Doc-RVM):
- **Option A — RVM (production-aligned):** install RVM (single-user under the
  account home, matching prod; include the GPG-key import step and link to the
  official RVM install command rather than pasting a curl-to-shell one-liner),
  then `rvm install jruby-9.4.15.0` and `rvm use jruby-9.4.15.0` (pin via
  `rvm --default use jruby-9.4.15.0` or a project `.ruby-version`). Then generate
  the systemd wrapper: `rvm wrapper jruby-9.4.15.0` →
  `~/.rvm/wrappers/jruby-9.4.15.0/jruby`, with a one-line pointer noting this is
  the path DEPLOYMENT.md's `ExecStart` uses. Finish with the same
  `ruby --version` → `jruby 9.4.15.0` check.
- **Option B — rbenv (local dev):** keep the existing rbenv instructions verbatim.
- Ensure the wrapper path, JRuby version, and per-user-home model match
  DEPLOYMENT.md exactly.

- [ ] **Step 5: INSTALL.md — honor `$TMPDIR` in the socket line (line ~218)**

Change only the innermost fallback from `/tmp` to `${TMPDIR:-/tmp}`:
```
FITS_SOCKET="${FITS_SOCKET_PATH:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}/fits-$(id -u)}/fits.sock}"
```
Leave the `FITS_SOCKET_PATH`/`XDG_RUNTIME_DIR` precedence untouched. Apply the same
change to the mirrored comment at INSTALL.md ~line 173/216 if it repeats the path.

- [ ] **Step 6: Verify CLAUDE.md + code comments for drift**

Re-read `CLAUDE.md` and the comments touched in Tasks 1–5 (the L10 byte-cap
contract comment, the L6 generic-error comment, the new `client_disconnects`
comment). Confirm none contradicts shipped behavior. No CLAUDE.md change is
anticipated — confirm and note it.

- [ ] **Step 7: Commit**

```bash
git add DEPLOYMENT.md INSTALL.md README.md
git commit -m "docs: align deployment on per-user RVM, correct STATS wording, honor \$TMPDIR

DEPLOYMENT: install JRuby via RVM under /var/fits with useradd --create-home,
ProtectHome=read-only, and ExecStart at the RVM wrapper; add client_disconnects
to STATS; correct requests_* wording; add an Operational trade-offs note
(L3/NEW-2/L9). INSTALL: add an RVM (production-aligned) option to Step 2 and
honor \$TMPDIR in the default socket path. README: correct STATS wording and add
client_disconnects.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final verification (after all tasks)

- [ ] `bundle exec rspec` — all fast specs green.
- [ ] `FITS_HOME=~/tools/fits-1.6.0 bundle exec rspec --tag integration` — integration specs green.
- [ ] `rake lint` and `rake audit` — clean.
- [ ] Final **opus** whole-branch review (`scripts/review-package $(git merge-base main HEAD) HEAD`) before finishing the branch.
