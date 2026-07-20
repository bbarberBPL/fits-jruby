# frozen_string_literal: true

require 'socket'
require 'logger'
require 'fileutils'
require_relative 'connection_reader'

module FitsJruby
  # Owns the UNIXServer lifecycle. An acceptor thread accepts connections and
  # pushes them onto a bounded queue; a single worker thread drains the queue
  # serially, so only one examination runs at a time.
  class SocketServer
    # Sentinel pushed onto the queue to signal the worker to shut down.
    SHUTDOWN = Object.new.freeze

    # Self-heal policy: cap consecutive rapid respawns so a worker that dies
    # immediately and repeatedly (sustained OOM, repeated fatal error) cannot
    # thrash the JVM with unbounded thread churn + a log flood.
    MAX_CONSECUTIVE_RESPAWNS = 5
    # A worker that has run healthily for at least this long (measured from its
    # last respawn) is considered recovered, so the consecutive-respawn counter
    # resets and a fresh transient crash still self-heals.
    RESPAWN_RESET_INTERVAL = 60 # seconds

    def initialize(config:, handler:, metrics:, logger: nil)
      @config = config
      @handler = handler
      @metrics = metrics
      @logger = logger || default_logger(config.log_level)
      @queue = SizedQueue.new(config.queue_capacity)
      @reader = ConnectionReader.new
      # Atomic so the flag written by stop is reliably observed by a worker's
      # ensure block even when the worker was terminated via Thread#kill (no
      # ordinary happens-before edge exists on that path). Prevents a respawn
      # from racing shutdown and leaking a thread blocked on @queue.pop.
      @running = java.util.concurrent.atomic.AtomicBoolean.new(false)
      @stopped = false
      @stop_mutex = Mutex.new
      @respawn_count = 0
      @last_respawn_at = nil
    end

    def socket_path
      @config.socket_path
    end

    def start
      remove_stale_socket
      @server = UNIXServer.new(socket_path)
      # Enforce 0660 in code rather than relying on the ambient umask, so a
      # permissive umask cannot yield a world-connectable socket. Group
      # ownership comes from the process's gid; we deliberately do not chown
      # (uid/gid mapping is deployment-specific).
      File.chmod(0o660, socket_path)
      @running.set(true)
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

      @running.set(false)
      # Order matters: stop ACCEPTING first, then drain the worker. Closing the
      # listening socket makes the acceptor's blocked accept raise IOError/EBADF
      # so it breaks; joining it guarantees no new connection can be enqueued
      # after the SHUTDOWN sentinel (which would otherwise be popped-past and
      # leak, hanging its client).
      close_server_socket  # unblocks the acceptor (closed socket raises IOError)
      join_acceptor        # guaranteed to exit now the listening socket is gone
      drain_worker         # push sentinel so worker exits after current serve
      drain_pending_connections # close anything left in the queue (fail fast)
      remove_stale_socket
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

    # After the worker has exited, close any connections still queued (enqueued
    # before shutdown but never served). Without this their clients would hang
    # until their own timeout; closing gives them a fast-failing closed socket.
    def drain_pending_connections
      loop do
        conn = @queue.pop(true)
        safe_close(conn) unless conn.equal?(SHUTDOWN)
      end
    rescue ThreadError
      # queue empty
    end

    def join_acceptor
      @acceptor&.join(1)
      @acceptor&.kill
    end

    def acceptor_loop
      while @running.get
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
      respawn_worker_if_crashed
    end

    # A clean shutdown pops the SHUTDOWN sentinel with @running already false, so
    # this is a no-op. Any other exit while @running is still true means the
    # worker died unexpectedly (e.g. @queue.pop or the sentinel check raised) —
    # the single worker is a SPOF (STATS is served by it too), so self-heal by
    # respawning. The atomic @running guard prevents a respawn loop after stop:
    # stop's @running.set(false) publishes a memory barrier the killed worker's
    # ensure reliably observes, so no worker is respawned during shutdown.
    #
    # Backoff + cap: if the worker keeps dying immediately (sustained OOM,
    # repeated fatal error) we would otherwise churn threads and flood the log.
    # We sleep a small increasing backoff before each respawn and, after
    # MAX_CONSECUTIVE_RESPAWNS rapid respawns, give up (log once, stay
    # degraded-but-not-thrashing). A worker that survives RESPAWN_RESET_INTERVAL
    # is treated as recovered and resets the counter, so a later transient crash
    # self-heals again.
    def respawn_worker_if_crashed
      return unless @running.get

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @respawn_count = 0 if @last_respawn_at && (now - @last_respawn_at) > RESPAWN_RESET_INTERVAL

      if @respawn_count >= MAX_CONSECUTIVE_RESPAWNS
        @logger.fatal("worker repeatedly crashed (#{@respawn_count} times); giving up respawning")
        return
      end

      @respawn_count += 1
      sleep [0.1 * @respawn_count, 5].min
      return unless @running.get # stop may have fired during the backoff sleep

      @last_respawn_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @logger.error("worker loop exited unexpectedly while running; respawning (attempt #{@respawn_count})")
      @worker = Thread.new { worker_loop }
    end

    def safe_close(connection)
      connection.close if connection.respond_to?(:close) && !connection.closed?
    rescue IOError, Errno::EBADF
      nil
    end

    def serve(connection)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      raw = @reader.read_line(connection, @config.read_timeout)
      response = @handler.handle(raw.to_s)
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

    # Write an early-exit error response (read timeout / request too long) and
    # record it. Best-effort: the client may already be gone.
    def write_read_error(connection, message)
      connection.write(message)
      @metrics.record_error
    rescue IOError, Errno::EPIPE, Errno::ECONNRESET
      @metrics.record_error
    end

    # Write the full response to the connection using a non-blocking loop
    # bounded by a monotonic deadline. Returns true on success, false if the
    # write timed out or the peer closed the connection (in which case the
    # error metric is recorded and a warning is logged). This prevents a
    # non-reading client from wedging the worker when the response is larger
    # than the socket send buffer.
    #
    # NOTE: JRuby raises Errno::EPIPE from write_nonblock even with
    # exception: false when the peer closes; we rescue it here so serve's
    # error-path logic stays clean.
    def write_response(connection, response)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @config.write_timeout
      offset   = 0
      total    = response.bytesize

      while offset < total
        written = connection.write_nonblock(response.byteslice(offset, total - offset), exception: false)
        if written == :wait_writable
          time_left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if time_left <= 0 || connection.wait_writable(time_left).nil?
            @logger.warn('write timeout for client; abandoning connection')
            @metrics.record_error
            return false
          end
        else
          offset += written
        end
      end
      true
    rescue Errno::EPIPE, Errno::ECONNRESET
      # Peer disconnected mid-write; not an error worth alarming on.
      false
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
