# frozen_string_literal: true

require 'socket'
require 'fits_jruby/connection_reader'

RSpec.describe FitsJruby::ConnectionReader do
  subject(:reader) { described_class.new }

  # A connected pair of Unix sockets: `client` writes, `server` is read by the
  # ConnectionReader — mirrors how SocketServer reads an accepted connection.
  let(:pair) { UNIXSocket.pair }
  let(:client) { pair[0] }
  let(:server) { pair[1] }

  after do
    client.close unless client.closed?
    server.close unless server.closed?
  end

  it 'reads a complete newline-terminated line including the newline' do
    client.write("/abs/path/to/file.tif\n")
    expect(reader.read_line(server, 2)).to eq("/abs/path/to/file.tif\n")
  end

  it 'reassembles a line delivered in multiple chunks under the timeout' do
    Thread.new do
      client.write('/abs/path/')
      sleep 0.05
      client.write("to/file.tif\n")
    end
    expect(reader.read_line(server, 2)).to eq("/abs/path/to/file.tif\n")
  end

  it 'returns nil on EOF (client closes without sending a newline)' do
    client.close
    expect(reader.read_line(server, 2)).to be_nil
  end

  it 'raises ReadTimeout when no data arrives before the deadline' do
    expect { reader.read_line(server, 0.1) }
      .to raise_error(FitsJruby::ConnectionReader::ReadTimeout)
  end

  it 'raises RequestTooLong when the cap is exceeded with no newline' do
    small = described_class.new(max_bytes: 16)
    client.write('x' * 64) # no newline, exceeds the 16-byte cap
    expect { small.read_line(server, 2) }
      .to raise_error(FitsJruby::ConnectionReader::RequestTooLong)
  end

  it 'reads a line exactly at the cap boundary' do
    boundary = described_class.new(max_bytes: 8)
    client.write("abcdefg\n") # 7 chars + newline = 8 bytes
    expect(boundary.read_line(server, 2)).to eq("abcdefg\n")
  end
end
