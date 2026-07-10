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
end
