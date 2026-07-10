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

  def build_server(examiner)
    metrics = FitsJruby::Metrics.new(heap_reader: -> { { used: 1, max: 2 } })
    config = FitsJruby::Config.new(
      'FITS_HOME' => '/unused', 'FITS_SOCKET_PATH' => @socket_path
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
