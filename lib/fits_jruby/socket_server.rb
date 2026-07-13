# frozen_string_literal: true

require 'socket'
require 'logger'
require 'fileutils'

module FitsJruby
  # Owns the UNIXServer lifecycle. An acceptor thread accepts connections and
  # pushes them onto a bounded queue; a single worker thread drains the queue
  # serially, so only one examination runs at a time.
  class SocketServer
    # Sentinel pushed onto the queue to signal the worker to shut down.
    SHUTDOWN = Object.new.freeze

    # Maximum bytes read from a single request line before giving up.
    # File paths are small; this prevents a runaway no-newline stream from
    # growing the heap unboundedly.
    MAX_REQUEST_BYTES = 4096

    # Internal error types used only within SocketServer to signal early exits
    # from read_line back to serve.
    class ReadTimeout < StandardError; end
    class RequestTooLong < StandardError; end

    def initialize(config:, handler:, metrics:, logger: nil)
      @config = config
      @handler = handler
      @metrics = metrics
      @logger = logger || default_logger(config.log_level)
      @queue = SizedQueue.new(config.queue_capacity)
      @running = false
      @stopped = false
      @stop_mutex = Mutex.new
    end

    def socket_path
      @config.socket_path
    end

    def start
      remove_stale_socket
      @server = UNIXServer.new(socket_path)
      @running = true
      @stopped = false
      @worker = Thread.new { worker_loop }
      @acceptor = Thread.new { acceptor_loop }
      @logger.info("ready: listening on #{socket_path} (queue capacity #{@config.queue_capacity})")
    end

    # Idempotent: safe to call multiple times or from concurrent signal handlers.
    # Never raises.
    def stop
      @stop_mutex.synchronize do
        return if @stopped

        @stopped = true
      end

      @running = false
      drain_worker         # push sentinel so worker exits after current serve
      close_server_socket  # unblocks the acceptor (closed socket raises IOError)
      remove_stale_socket
      join_acceptor
      @logger.info('stopped')
    end

    private

    def close_server_socket
      @server&.close
    rescue IOError, Errno::EBADF
      # already closed; harmless
    end

    def drain_worker
      @queue.push(SHUTDOWN) if @worker
      return unless @worker && !@worker.join(5)

      @logger.warn('worker did not stop in 5s; killing')
      @worker.kill
    end

    def join_acceptor
      @acceptor&.join(1)
      @acceptor&.kill
    end

    def acceptor_loop
      while @running
        begin
          connection = @server.accept
          @metrics.enqueue
          @queue.push(connection)
        rescue IOError, Errno::EBADF
          break
        rescue StandardError => e
          @logger.error("acceptor error: #{e.class}: #{e.message}")
        end
      end
    end

    def worker_loop
      loop do
        connection = @queue.pop
        break if connection.equal?(SHUTDOWN)

        begin
          @metrics.dequeue
          @metrics.processing = true
          serve(connection)
        rescue Exception => e # rubocop:disable Lint/RescueException
          # Catches java.lang.Throwable (including Java Errors like
          # StackOverflowError) that bypass rescue StandardError.
          @logger.error("worker loop unhandled exception: #{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}")
          safe_close(connection)
        ensure
          @metrics.processing = false
        end
      end
    ensure
      @logger.error('worker loop exited unexpectedly while running') if @running
    end

    def safe_close(connection)
      connection.close if connection.respond_to?(:close) && !connection.closed?
    rescue IOError, Errno::EBADF
      nil
    end

    # Read a newline-terminated request line with a timeout and size cap.
    # Returns the line (including trailing newline), nil on EOF/close,
    # raises ReadTimeout on timeout, raises RequestTooLong when cap exceeded.
    def read_line(connection, read_timeout) # rubocop:disable Metrics/AbcSize
      buf = +''
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + read_timeout

      loop do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise ReadTimeout if remaining <= 0

        raise ReadTimeout unless connection.wait_readable(remaining)

        chunk = connection.read_nonblock(MAX_REQUEST_BYTES - buf.length + 1, exception: false)
        next if chunk == :wait_readable # shouldn't happen after wait_readable, but be safe

        return nil if chunk.nil? # EOF

        buf << chunk
        newline_idx = buf.index("\n")
        return buf[0..newline_idx] if newline_idx

        raise RequestTooLong if buf.length >= MAX_REQUEST_BYTES
      end
    end

    def serve(connection) # rubocop:disable Metrics/AbcSize
      started       = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      read_timeout  = @config.read_timeout
      write_timeout = @config.write_timeout

      begin
        raw = read_line(connection, read_timeout)
      rescue ReadTimeout
        connection.write('ERROR: read timeout')
        return
      rescue RequestTooLong
        connection.write('ERROR: request too long')
        return
      end

      response = @handler.handle(raw.to_s)

      # Guard the write so a non-reading client can't block the worker.
      if connection.wait_writable(write_timeout)
        connection.write(response)
        record_outcome(response)
        log_request(raw, response, started)
      else
        @logger.warn('write timeout for client; abandoning connection')
      end
    rescue StandardError => e
      @logger.error("worker error: #{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}")
    ensure
      safe_close(connection)
    end

    def record_outcome(response)
      if response.start_with?('<?xml')
        @metrics.record_success
      elsif response.start_with?('ERROR:')
        @metrics.record_error
      end
    end

    def log_request(raw, response, started)
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      request = raw.to_s.strip
      if request == RequestHandler::STATS_COMMAND
        @logger.debug("stats request (#{duration_ms}ms)")
      else
        outcome = response.start_with?('<?xml') ? 'success' : 'error'
        @logger.info("examine path=#{request} outcome=#{outcome} duration_ms=#{duration_ms}")
      end
    end

    def remove_stale_socket
      FileUtils.rm_f(socket_path)
    end

    def default_logger(level)
      logger = Logger.new($stdout)
      logger.level = Logger.const_get(level.to_s.upcase)
      logger
    end
  end
end
