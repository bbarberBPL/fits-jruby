# frozen_string_literal: true

module FitsJruby
  # Reads a single newline-terminated request line from a socket, bounded by a
  # timeout and a maximum byte count. Stateless and reusable across
  # connections. Extracted from SocketServer so the line protocol can be tested
  # in isolation (via UNIXSocket.pair) rather than only end-to-end.
  class ConnectionReader
    # Maximum bytes read from a single request line before giving up. File
    # paths are small; this prevents a runaway no-newline stream from growing
    # the heap unboundedly.
    DEFAULT_MAX_BYTES = 4096

    # Raised when no complete line arrives before the timeout elapses.
    class ReadTimeout < StandardError; end
    # Raised when the byte cap is reached without encountering a newline.
    class RequestTooLong < StandardError; end

    def initialize(max_bytes: DEFAULT_MAX_BYTES)
      @max_bytes = max_bytes
    end

    # Read a newline-terminated request line with a timeout and size cap.
    # Returns the line (including the trailing newline), nil on EOF/close,
    # raises ReadTimeout on timeout, raises RequestTooLong when the cap is
    # exceeded.
    def read_line(connection, timeout) # rubocop:disable Metrics/AbcSize
      buf = +''
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

      loop do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise ReadTimeout if remaining <= 0

        raise ReadTimeout unless connection.wait_readable(remaining)

        chunk = connection.read_nonblock(@max_bytes - buf.length + 1, exception: false)
        next if chunk == :wait_readable # shouldn't happen after wait_readable, but be safe

        return nil if chunk.nil? # EOF

        buf << chunk
        newline_idx = buf.index("\n")
        return buf[0..newline_idx] if newline_idx

        raise RequestTooLong if buf.length >= @max_bytes
      end
    end
  end
end
