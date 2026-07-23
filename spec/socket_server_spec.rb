# frozen_string_literal: true

require 'socket'
require 'tmpdir'
require 'timeout'
require 'json'
require 'tempfile'
require 'fits_jruby/config'
require 'fits_jruby/metrics'
require 'fits_jruby/request_handler'
require 'fits_jruby/socket_server'
require_relative 'support/fake_examiner'

RSpec.describe FitsJruby::SocketServer do
  around do |example|
    Dir.mktmpdir do |dir|
      @socket_path = File.join(dir, 'test.sock')
      example.run
    end
  end

  # Short timeouts so the timeout-related tests complete quickly.
  def build_server(examiner, extra_env = {})
    metrics = FitsJruby::Metrics.new(heap_reader: -> { { used: 1, max: 2 } })
    config = FitsJruby::Config.new(
      {
        'FITS_HOME' => '/unused',
        'FITS_SOCKET_PATH' => @socket_path,
        'FITS_READ_TIMEOUT' => '1',
        'FITS_WRITE_TIMEOUT' => '5'
      }.merge(extra_env)
    )
    handler = FitsJruby::RequestHandler.new(examiner: examiner, metrics: metrics)
    [FitsJruby::SocketServer.new(config: config, handler: handler, metrics: metrics), metrics]
  end

  def request(path_line)
    UNIXSocket.open(@socket_path) do |sock|
      sock.write("#{path_line}\n")
      sock.read
    end
  end

  def wait_for_socket
    20.times do
      break if File.socket?(@socket_path)

      sleep 0.05
    end
  end

  it 'returns examiner XML for a valid path and increments success' do
    server, metrics = build_server(FakeExaminer.new)
    server.start
    wait_for_socket
    Tempfile.create(['s', '.tif']) do |file|
      expect(request(file.path)).to eq('<?xml version="1.0"?><fits/>')
    end
    expect(metrics.snapshot[:requests_success]).to eq(1)
  ensure
    server&.stop
  end

  it 'returns an error line and increments error for a bad path' do
    server, metrics = build_server(FakeExaminer.new)
    server.start
    wait_for_socket
    expect(request('/does/not/exist.tif')).to match(/\AERROR: /)
    expect(metrics.snapshot[:requests_error]).to eq(1)
  ensure
    server&.stop
  end

  it 'answers STATS with JSON and counts it as neither success nor error' do
    server, metrics = build_server(FakeExaminer.new)
    server.start
    wait_for_socket
    body = request('STATS')
    expect(JSON.parse(body)).to include('requests_total')
    snap = metrics.snapshot
    expect(snap[:requests_success]).to eq(0)
    expect(snap[:requests_error]).to eq(0)
  ensure
    server&.stop
  end

  it 'survives an examiner that raises and keeps serving' do
    server, = build_server(FakeExaminer.new(raise_with: 'boom'))
    server.start
    wait_for_socket
    Tempfile.create(['s', '.tif']) do |file|
      expect(request(file.path)).to eq('ERROR: examination failed')
      # server still responds afterward
      expect(request('STATS')).to start_with('{')
    end
  ensure
    server&.stop
  end

  # ── Fix 1: idempotent stop ────────────────────────────────────────────────

  it 'does not raise when stop is called twice' do
    server, = build_server(FakeExaminer.new)
    server.start
    wait_for_socket
    expect { server.stop }.not_to raise_error
    expect { server.stop }.not_to raise_error
  end

  it 'removes the socket file and rejects new connections after stop' do
    server, = build_server(FakeExaminer.new)
    server.start
    wait_for_socket
    server.stop
    expect(File.exist?(@socket_path)).to be(false)
    expect { UNIXSocket.new(@socket_path) }.to raise_error(Errno::ENOENT, /No such file/)
  end

  # ── Fix A: shutdown race — queued connections are closed, never leaked ─────
  #
  # A connection that was enqueued before shutdown but is still sitting in the
  # queue when the worker exits (e.g. the worker had to be killed mid-serve)
  # must be closed by drain_pending_connections, so its client fails fast on a
  # closed socket rather than hanging until its own timeout.
  #
  # Determinism: we occupy the worker with an in-flight examine that blocks on a
  # latch, so the connection we enqueue afterward is GUARANTEED to still be in
  # the queue (the busy worker cannot pop it). We then invoke the drain directly
  # and prove IT — not the worker — is what closed the leftover.
  it 'drains and closes connections left in the queue instead of leaking them' do
    latch_start = Queue.new
    latch_resume = Queue.new
    slow = Object.new
    slow.define_singleton_method(:examine) do |_path|
      latch_start.push(:ready)
      latch_resume.pop
      '<?xml version="1.0"?><fits/>'
    end

    server, = build_server(slow)
    server.start
    wait_for_socket

    # Occupy the single worker with an in-flight, blocked examine.
    Thread.new { Tempfile.create(['a', '.tif']) { |f| request(f.path) } }
    latch_start.pop

    queue = server.instance_variable_get(:@queue)
    closed = false
    leftover = Object.new
    leftover.define_singleton_method(:closed?) { false }
    leftover.define_singleton_method(:close) { closed = true }
    queue.push(leftover)

    # The worker is busy, so the leftover is still queued — not yet closed.
    expect(closed).to be(false)

    # The drain (not the worker) closes it.
    server.send(:drain_pending_connections)
    expect(closed).to be(true)

    latch_resume.push(:go) # release the in-flight serve so stop can finish
  ensure
    server&.stop
  end

  it 'completes stop promptly and closes a connection queued behind an in-flight serve' do
    latch_start = Queue.new
    latch_resume = Queue.new
    slow = Object.new
    slow.define_singleton_method(:examine) do |_path|
      latch_start.push(:ready)
      latch_resume.pop
      '<?xml version="1.0"?><fits/>'
    end

    server, = build_server(slow)
    server.start
    wait_for_socket

    # Occupy the worker.
    Thread.new do
      Tempfile.create(['a', '.tif']) { |f| request(f.path) }
    end
    latch_start.pop

    # Enqueue a second connection that will sit in the queue during shutdown.
    queued = UNIXSocket.new(@socket_path)

    # Let the in-flight serve finish, then stop.
    latch_resume.push(:go)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    server.stop
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    expect(elapsed).to be < 6 # no indefinite hang; well under worker kill(5s)

    # The queued client must be closed promptly (served-then-closed or drained),
    # NOT left hanging. Prove it with a bounded read that must return, never
    # block indefinitely.
    read_result = Thread.new do
      queued.read
    rescue Errno::ECONNRESET, IOError
      :closed
    end.join(5)
    expect(read_result).not_to be_nil # the read returned; no indefinite hang
  ensure
    queued&.close rescue nil # rubocop:disable Style/RescueModifier
  end

  # ── Fix B: socket mode enforced at 0660 regardless of umask ────────────────

  it 'creates the socket with mode 0660 regardless of the ambient umask' do
    server, = build_server(FakeExaminer.new)
    old_umask = File.umask(0o000) # permissive umask would yield 0777 without chmod
    begin
      server.start
      wait_for_socket
      expect(File.stat(@socket_path).mode & 0o777).to eq(0o660)
    ensure
      File.umask(old_umask)
      server.stop
    end
  end

  # ── Fix C: worker self-heals if it dies unexpectedly while running ─────────

  it 'respawns the worker if it dies unexpectedly and keeps serving' do
    server, = build_server(FakeExaminer.new)
    server.start
    wait_for_socket

    original = server.instance_variable_get(:@worker)
    # Simulate an unexpected worker death while @running is true. Thread#kill
    # runs the worker_loop ensure block, which respawns because @running.
    original.kill
    original.join

    # Give the respawn a moment.
    20.times do
      break if server.instance_variable_get(:@worker) != original

      sleep 0.05
    end

    current = server.instance_variable_get(:@worker)
    expect(current).not_to equal(original)
    expect(current.alive?).to be(true)

    # And the server still answers a request.
    expect(request('STATS')).to start_with('{')
  ensure
    server&.stop
  end

  # ── Fix 1: @running is atomic so stop never respawns during shutdown ───────
  #
  # The worker KILL-fallback path (drain_worker's join(5) timeout → @worker.kill)
  # runs the worker_loop ensure, which reads @running. With a plain non-volatile
  # boolean there is no happens-before edge between stop's write and that
  # killed-thread read, so the JVM could observe a stale `true` and respawn a
  # worker during shutdown — leaking a thread blocked on @queue.pop. The atomic
  # gives the memory barrier. Forcing the real 5s kill path in a unit test would
  # need a 5s+ block, so we assert the invariant directly: stop clears the
  # atomic before draining, and the respawn guard reads it and refuses.
  it 'uses an atomic for @running so the respawn guard reliably sees shutdown' do
    server, = build_server(FakeExaminer.new)
    server.start
    wait_for_socket

    running = server.instance_variable_get(:@running)
    expect(running).to be_a(java.util.concurrent.atomic.AtomicBoolean)
    expect(running.get).to be(true)

    server.stop

    # stop cleared the atomic (memory-barrier publish observed by any thread).
    expect(running.get).to be(false)
    # The worker is not alive and was not respawned during shutdown.
    expect(server.instance_variable_get(:@worker).alive?).to be(false)
  end

  it 'does not respawn a worker when the guard runs after stop (kill-path invariant)' do
    server, = build_server(FakeExaminer.new)
    server.start
    wait_for_socket
    server.stop

    worker_before = server.instance_variable_get(:@worker)
    # Directly invoke the guard exactly as a killed worker's ensure would; with
    # @running already false it must be a no-op — no new thread, no log spam.
    expect { server.send(:respawn_worker_if_crashed) }.not_to raise_error
    expect(server.instance_variable_get(:@worker)).to equal(worker_before)
    expect(worker_before.alive?).to be(false)
  end

  # ── Fix 2: respawn backoff + cap prevents thrash on persistent failure ─────

  it 'stops respawning after repeated rapid crashes and logs a single fatal' do
    server, = build_server(FakeExaminer.new)
    server.start
    wait_for_socket

    logger = server.instance_variable_get(:@logger)
    fatal_messages = []
    logger.define_singleton_method(:fatal) { |msg| fatal_messages << msg }

    # Stub the terminal action so the give-up branch does not exit the runner.
    terminal_calls = 0
    server.instance_variable_set(:@on_repeated_crash, -> { terminal_calls += 1 })

    # Simulate the cap already being reached; the next guard call must give up.
    server.instance_variable_set(:@respawn_count,
                                 FitsJruby::SocketServer::MAX_CONSECUTIVE_RESPAWNS)
    worker_before = server.instance_variable_get(:@worker)

    server.send(:respawn_worker_if_crashed)

    expect(server.instance_variable_get(:@worker)).to equal(worker_before)
    expect(fatal_messages.size).to eq(1)
    expect(fatal_messages.first).to match(/repeatedly crashed/)
    # The terminal action fires exactly once so the supervisor restarts a
    # clean process rather than leaving a workerless (hung) server.
    expect(terminal_calls).to eq(1)
  ensure
    server&.stop
  end

  # ── Fix: give-up path exits so supervisor restarts; transient crash does not ─
  #
  # The default terminal action is java.lang.System.exit(1); a spec must never
  # trigger it (it would kill the runner), so we stub it and assert the seam
  # fires exactly once when the cap is exceeded and NOT on a single transient
  # crash (which must still self-heal by respawning).
  it 'defaults the terminal crash action to a callable hard exit' do
    server, = build_server(FakeExaminer.new)
    # Inspect the default seam WITHOUT invoking it (calling it would exit).
    action = server.send(:on_repeated_crash)
    expect(action).to respond_to(:call)
    expect(action).to be_a(Proc)
  end

  it 'does not fire the terminal action on a single transient crash (self-heals)' do
    server, = build_server(FakeExaminer.new)
    server.start
    wait_for_socket

    terminal_calls = 0
    server.instance_variable_set(:@on_repeated_crash, -> { terminal_calls += 1 })

    original = server.instance_variable_get(:@worker)
    # One unexpected death: the guard must respawn, not give up/exit.
    original.kill
    original.join

    20.times do
      break if server.instance_variable_get(:@worker) != original

      sleep 0.05
    end

    expect(terminal_calls).to eq(0)
    expect(server.instance_variable_get(:@worker)).not_to equal(original)
    expect(server.instance_variable_get(:@worker).alive?).to be(true)
  ensure
    server&.stop
  end

  it 'does not fire the terminal action on a normal clean stop' do
    server, = build_server(FakeExaminer.new)
    server.start
    wait_for_socket

    terminal_calls = 0
    server.instance_variable_set(:@on_repeated_crash, -> { terminal_calls += 1 })

    server.stop
    # The guard is a no-op after stop (@running false), so even if invoked
    # directly as a killed worker's ensure would, it must not exit.
    server.send(:respawn_worker_if_crashed)

    expect(terminal_calls).to eq(0)
  end

  # ── Fix C1: read timeout — stalled client does not wedge the worker ──────

  it 'responds with ERROR: read timeout when client connects but never sends a newline' do
    server, = build_server(FakeExaminer.new)
    server.start
    wait_for_socket

    response = nil
    UNIXSocket.open(@socket_path) do |sock|
      # Do NOT write anything; wait for server to time out and close the conn.
      response = sock.read
    end

    expect(response).to match(/\AERROR: read timeout/)

    # Worker must still be alive: a normal request succeeds afterward.
    Tempfile.create(['s', '.tif']) do |file|
      expect(request(file.path)).to start_with('<?xml')
    end
  ensure
    server&.stop
  end

  # ── Fix C1: oversize line — unbounded input capped, worker keeps serving ─

  it 'rejects an oversize request line and keeps serving subsequent requests' do
    server, = build_server(FakeExaminer.new)
    server.start
    wait_for_socket

    # Send more than the request-line byte cap without a newline.
    oversized = ('A' * (FitsJruby::ConnectionReader::DEFAULT_MAX_BYTES + 100))
    response = nil
    begin
      UNIXSocket.open(@socket_path) do |sock|
        sock.write(oversized)
        response = sock.read
      end
    rescue Errno::ECONNRESET, Errno::EPIPE, IOError
      # Server may close the socket while client's send buffer still has data;
      # on Unix domain sockets this yields ECONNRESET. Both "ERROR: request too
      # long" and an abrupt close are acceptable rejection responses.
      nil
    end

    # If we got a response at all, it must be the expected error message.
    expect(response).to match(/\AERROR: request too long/) unless response.nil?

    # The important invariant: the worker is still alive.
    Tempfile.create(['s', '.tif']) do |file|
      expect(request(file.path)).to start_with('<?xml')
    end
  ensure
    server&.stop
  end

  # ── Fix I1: worker survives a Java-level Error ────────────────────────────

  it 'survives an examiner that raises a Java Error and keeps serving' do
    server, = build_server(FakeExaminer.new(raise_java_error: true))
    server.start
    wait_for_socket

    Tempfile.create(['s', '.tif']) do |file|
      # The erroring request: the worker may close without a full response, OR
      # return an ERROR: line — either is acceptable.
      begin
        UNIXSocket.open(@socket_path) do |sock|
          sock.write("#{file.path}\n")
          sock.read # may be empty if worker closed early
        end
      rescue StandardError
        nil # connection reset is fine — worker survived is what we test
      end

      # Worker must still be alive: a STATS request succeeds.
      expect(request('STATS')).to start_with('{')
    end
  ensure
    server&.stop
  end

  # ── Fix (bounded write): write_response loop terminates on timeout ──────────
  #
  # NOTE: SO_RCVBUF is not settable on Unix domain sockets on Linux —
  # setsockopt raises Errno::ENOPROTOOPT (the option is only valid for IP
  # sockets). Instead, write_response is tested at the unit level using a
  # pre-filled real socket pair, and the worker-not-wedged invariant is
  # separately exercised via an integration test with a large response.

  it 'write_response returns false and records error when the write buffer is saturated' do
    reader, writer = UNIXSocket.pair

    begin
      # Fill reader's receive buffer by writing to writer until :wait_writable.
      fill = 'x' * 65_536
      loop do
        break if writer.write_nonblock(fill, exception: false) == :wait_writable
      end

      # Instantiate the server but do NOT start it; write_response only needs
      # @config (write_timeout) and @metrics.
      server, metrics = build_server(FakeExaminer.new, 'FITS_WRITE_TIMEOUT' => '1')
      result = server.send(:write_response, writer, 'hello world')

      expect(result).to be(false)
      expect(metrics.snapshot[:requests_error]).to eq(1)
    ensure
      reader.close rescue nil # rubocop:disable Style/RescueModifier
      writer.close rescue nil # rubocop:disable Style/RescueModifier
    end
  end

  it 'does not wedge the worker when a client stops reading a large response' do
    # SO_RCVBUF is unsettable on Unix domain sockets; write_timeout unit
    # coverage is in the test above.  This test guards the critical invariant:
    # the worker must still serve subsequent requests after a slow client.
    large_xml = "<?xml #{'a' * 600_000}"
    server, = build_server(FakeExaminer.new(xml: large_xml), 'FITS_WRITE_TIMEOUT' => '1')
    server.start
    wait_for_socket

    Tempfile.create(['test', '.tif']) do |tmp|
      sock = UNIXSocket.new(@socket_path)
      begin
        sock.write("#{tmp.path}\n")
        # Do NOT read — let write_timeout (1 s) fire or buffer to saturate.
        sleep 2
      rescue IOError, Errno::ECONNRESET, Errno::EPIPE
        nil # server may close the connection during timeout handling
      ensure
        sock.close rescue nil # rubocop:disable Style/RescueModifier
      end
    end

    # Critical invariant: worker must still be alive regardless of whether
    # the write timed out or succeeded.
    Tempfile.create(['s', '.tif']) do |file|
      expect(request(file.path)).to start_with('<?xml')
    end
  ensure
    server&.stop
  end

  # ── Fix (metrics): error counter incremented on read-timeout / oversize / write-timeout ──

  it 'increments requests_error after a read timeout' do
    server, metrics = build_server(FakeExaminer.new)
    server.start
    wait_for_socket

    UNIXSocket.open(@socket_path, &:read)

    expect(metrics.snapshot[:requests_error]).to eq(1)
    expect(metrics.snapshot[:requests_success]).to eq(0)
  ensure
    server&.stop
  end

  it 'increments requests_success after a normal success and does not increment error' do
    server, metrics = build_server(FakeExaminer.new)
    server.start
    wait_for_socket

    Tempfile.create(['s', '.tif']) do |file|
      expect(request(file.path)).to start_with('<?xml')
    end

    expect(metrics.snapshot[:requests_success]).to eq(1)
    expect(metrics.snapshot[:requests_error]).to eq(0)
  ensure
    server&.stop
  end

  it 'increments neither success nor error after a STATS request' do
    server, metrics = build_server(FakeExaminer.new)
    server.start
    wait_for_socket

    body = request('STATS')
    expect(JSON.parse(body)).to include('requests_total')

    snap = metrics.snapshot
    expect(snap[:requests_success]).to eq(0)
    expect(snap[:requests_error]).to eq(0)
  ensure
    server&.stop
  end

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
      expect { server.send(:verify_socket_dir!, '/tmp/fits-x') }.to raise_error(/mode 0777/)
    end

    it 'raises when the dir is owned by another uid' do
      server = tmpdir_fallback_server
      allow(File).to receive(:lstat).and_return(fake_stat(uid: Process.uid + 1))
      expect { server.send(:verify_socket_dir!, '/tmp/fits-x') }.to raise_error(/owned by uid/)
    end

    it 'raises when the path is a symlink' do
      server = tmpdir_fallback_server
      allow(File).to receive(:lstat).and_return(fake_stat(symlink: true))
      expect { server.send(:verify_socket_dir!, '/tmp/fits-x') }.to raise_error(/not a directory/)
    end
  end

  it 'start refuses an explicit FITS_SOCKET_PATH dir even if 0777 (check is tmpdir-only)' do
    # build_server sets FITS_SOCKET_PATH, so default_tmpdir_socket? is false and
    # the strict 0700/owner check must NOT run. Make the parent dir 0777: if the
    # check erroneously ran it would raise; a clean start proves it was skipped.
    server, = build_server(FakeExaminer.new)
    File.chmod(0o777, File.dirname(@socket_path))
    server.start
    wait_for_socket
    expect(File.socket?(@socket_path)).to be(true)
  ensure
    server&.stop
  end

  # ── Task 3: socket parent dir creation + double-start guard ────────────────

  describe 'start' do
    it 'creates the socket parent directory (0700) when missing' do
      nested = File.join(File.dirname(@socket_path), 'nested', 'fits.sock')
      server, = build_server(FakeExaminer.new, 'FITS_SOCKET_PATH' => nested)
      server.start
      begin
        dir = File.dirname(nested)
        expect(Dir.exist?(dir)).to be(true)
        expect(File.stat(dir).mode & 0o777).to eq(0o700)
      ensure
        server&.stop
      end
    end

    it 'raises if started while already running' do
      server, = build_server(FakeExaminer.new)
      server.start
      begin
        expect { server.start }.to raise_error(/already running/)
      ensure
        server&.stop
      end
    end
  end

  # ── H2/M1: stop must not deadlock pushing a shutdown signal onto a full
  # queue when the worker is not consuming (crashed + in respawn backoff). ────
  it 'completes stop without hanging when the queue is full and the worker is not consuming' do
    server, = build_server(FakeExaminer.new, 'FITS_QUEUE_CAPACITY' => '1')
    server.start
    wait_for_socket

    # Neutralize respawn FIRST — the killed worker's ensure invokes
    # respawn_worker_if_crashed on its own thread, so it must already be a
    # no-op before we kill, or an in-flight respawn spawns a consumer that
    # drains the queue and masks the blocking-push hang this test targets.
    def server.respawn_worker_if_crashed = nil
    worker = server.instance_variable_get(:@worker)
    worker.kill
    worker.join
    # @running AtomicBoolean reset dropped: respawn is stubbed regardless of
    # @running, so the reset was not needed for the precondition. After stop
    # runs, @running is set false by stop itself.

    # Fill the bounded queue (capacity 1) so a blocking push would wedge.
    queue = server.instance_variable_get(:@queue)
    queue.push(Object.new)

    finished = Thread.new { server.stop }.join(6)
    expect(finished).not_to be_nil # stop returned; no indefinite hang
  end

  # ── Fix 2: graceful drain — in-flight response is never truncated ─────────

  it 'delivers the complete response for an in-flight request when stop is called concurrently' do
    xml_body = ('X' * 4096)
    large_xml = "<?xml version=\"1.0\"?>#{xml_body}</fits>"
    latch_start = Queue.new   # signals when examine has been entered
    latch_resume = Queue.new  # signals examine to return

    slow_examiner = Object.new
    slow_examiner.define_singleton_method(:examine) do |_path|
      latch_start.push(:ready)
      latch_resume.pop # block until the test lets us proceed
      large_xml
    end

    server, = build_server(slow_examiner)
    server.start
    wait_for_socket

    response = nil
    client_thread = Thread.new do
      Tempfile.create(['s', '.tif']) do |file|
        response = request(file.path)
      end
    end

    # Wait until examine is running, then trigger stop.
    latch_start.pop
    stop_thread = Thread.new { server.stop }

    # Let examine return so the worker can finish writing the full response.
    latch_resume.push(:go)

    client_thread.join(10)
    stop_thread.join(10)

    expect(response).to start_with('<?xml')
    expect(response).to end_with('</fits>')
    expect(response.length).to eq(large_xml.length)
  end

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
      client.close
      sock.close
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
      # Close sock to send EOF so client.read (no length) returns the buffered data.
      # The brief used read(20) but 'ERROR: read timeout' is 19 bytes, causing a
      # deadlock (read(n) blocks until n bytes OR EOF; sock is still open here).
      sock.close
      expect(client.read).to eq('ERROR: read timeout')
    ensure
      client.close rescue nil # rubocop:disable Style/RescueModifier
      sock.close rescue nil   # rubocop:disable Style/RescueModifier
    end

    it 'does not block on a non-reading client and records the error once (L5)' do
      server = build_bare_server(write_timeout: 1)
      peer, sock = UNIXSocket.pair # peer never reads
      big = "ERROR: #{'x' * 5_000_000}"
      # Stub write_nonblock to never make progress so the deadline is what ends it.
      allow(sock).to receive(:write_nonblock).and_return(:wait_writable)
      allow(sock).to receive(:wait_writable).and_return(nil)
      result = nil
      thread = Thread.new { result = server.send(:write_read_error, sock, big) }
      expect(thread.join(5)).not_to be_nil # returned within the bounded time, did not hang
      expect(metrics.snapshot[:requests_error]).to eq(1)
    ensure
      peer.close
      sock.close
    end
  end

  # ── L4: client disconnect accounting ────────────────────────────────────────

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
end
