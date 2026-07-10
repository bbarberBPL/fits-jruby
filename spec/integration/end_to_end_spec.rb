# frozen_string_literal: true

require 'socket'
require 'tmpdir'
require 'json'

RSpec.describe 'fits-server end to end', :integration do
  fits_home = ENV.fetch('FITS_HOME', nil)

  before(:all) do
    skip 'FITS_HOME not set' if fits_home.nil? || fits_home.empty?
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @socket = File.join(dir, 'e2e.sock')
      env = { 'FITS_HOME' => fits_home, 'FITS_SOCKET_PATH' => @socket, 'JRUBY_OPTS' => '-J-Xmx512m' }
      @pid = spawn(env, 'bin/fits-server')
      120.times do
        break if File.socket?(@socket)

        sleep 0.25
      end
      example.run
    ensure
      if @pid
        begin
          Process.kill('TERM', @pid)
        rescue Errno::ESRCH
          # Process already exited
        end
        begin
          Process.wait(@pid)
        rescue Errno::ECHILD, Errno::ESRCH
          # Process already reaped or doesn't exist
        end
      end
    end
  end

  def request(line)
    UNIXSocket.open(@socket) do |sock|
      sock.write("#{line}\n")
      sock.read
    end
  end

  it 'returns real FITS XML for a fixture over the socket' do
    xml = request(File.expand_path('../fixtures/sample.tif', __dir__))
    expect(xml).to start_with('<?xml')
    expect(xml).to include('image/tiff')
  end

  it 'answers STATS with a JSON snapshot' do
    snap = JSON.parse(request('STATS'))
    expect(snap).to include('requests_total', 'heap_used_bytes', 'queue_depth')
  end
end
