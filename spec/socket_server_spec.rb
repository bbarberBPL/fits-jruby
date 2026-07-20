# frozen_string_literal: true

require 'socket'
require 'tmpdir'
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
      expect(request(file.path)).to eq('ERROR: examination failed: boom')
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
end
