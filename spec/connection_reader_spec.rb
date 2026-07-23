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

  describe 'byte cap contract (L10)' do
    def deliver(chunks, max_bytes:)
      client, server = UNIXSocket.pair
      reader = described_class.new(max_bytes: max_bytes)
      writer = Thread.new do
        chunks.each do |c|
          client.write(c)
          sleep 0.01
        end
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
      line = "#{'a' * 7}\n" # 8 bytes total
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

    it 'rejects a line whose newline lands one byte past the cap (guards the +1 off-by-one)' do
      # 9 bytes total (8 'a' + newline) with cap 8. Old code read max_bytes+1
      # bytes, saw the newline at index 8, and wrongly ACCEPTED the 9-byte line.
      # New code caps the read at 8 bytes, never sees the newline, and raises.
      line = "#{'a' * 8}\n"
      expect { deliver([line], max_bytes: 8) }
        .to raise_error(described_class::RequestTooLong)
    end
  end
end
