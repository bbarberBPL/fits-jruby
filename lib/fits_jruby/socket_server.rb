# frozen_string_literal: true

require 'socket'
require 'logger'
require 'fileutils'
require_relative 'connection_reader'

module FitsJruby
  # Owns the UNIXServer lifecycle. An acceptor thread accepts connections and
  # pushes them onto a bounded queue; a single worker thread drains the queue
  # serially, so only one examination runs at a time.
  class SocketServer # rubocop:disable Metrics/ClassLength
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
      raise 'server already running' if @running.get

      ensure_socket_dir
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
      # Order matters: stop ACCEPTING first, then signal the worker. Closing the
      # listening socket makes the acceptor's blocked accept raise IOError/EBADF
      # so it breaks; joining it guarantees no new connection is enqueued after
      # the queue is closed. Closing the queue (never blocks) unblocks every
      # pop — including a raced respawn — via a nil return once the queue drains.
      close_server_socket  # unblocks the acceptor (closed socket raises IOError)
      join_acceptor        # guaranteed to exit now the listening socket is gone
      drain_worker         # close queue so worker exits after current serve
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
      @queue.close
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
        break if conn.nil? # closed and empty

        safe_close(conn)
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
        rescue ClosedQueueError
          safe_close(connection) # queue closed mid-push; close the fd
          break
        rescue StandardError => e
          @logger.error("acceptor error: #{e.class}: #{e.message}")
        end
      end
    end

    def worker_loop
      loop do
        connection = @queue.pop
        break if connection.nil? # queue closed (shutdown) and drained

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

    # A clean shutdown exits via a nil pop (@running false) — this is a no-op.
    # Any other exit while @running is true means an unexpected crash; self-heal
    # by respawning. The atomic @running guard prevents a respawn loop: stop sets
    # it false before the worker is killed, so the killed thread's ensure sees it
    # and skips respawn.
    #
    # Backoff + cap: repeated rapid crashes (OOM, fatal error) would churn
    # threads and flood the log. We sleep an increasing backoff and give up after
    # MAX_CONSECUTIVE_RESPAWNS. On give-up we invoke the terminal action
    # (@on_repeated_crash, hard exit by default) so the supervisor restarts a
    # clean process. A worker surviving RESPAWN_RESET_INTERVAL resets the
    # counter so a later transient crash self-heals again.
    def respawn_worker_if_crashed
      return unless @running.get

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @respawn_count = 0 if @last_respawn_at && (now - @last_respawn_at) > RESPAWN_RESET_INTERVAL

      if @respawn_count >= MAX_CONSECUTIVE_RESPAWNS
        @logger.fatal("worker repeatedly crashed (#{@respawn_count} times); giving up respawning")
        on_repeated_crash.call
        return
      end

      @respawn_count += 1
      sleep [0.1 * @respawn_count, 5].min
      return unless @running.get # stop may have fired during the backoff sleep

      @last_respawn_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @logger.error("worker loop exited unexpectedly while running; respawning (attempt #{@respawn_count})")
      @worker = Thread.new { worker_loop }
    end

    # Terminal action taken when the worker crashes past the respawn cap.
    # Behind a seam (memoized, overridable via @on_repeated_crash) so it is
    # testable without exiting the test runner: the default hard-exits non-zero
    # so systemd's Restart=on-failure fires; a spec sets @on_repeated_crash to
    # record the call instead. java.lang.System.exit is used over Kernel#exit
    # because this runs on the crashed worker thread's ensure path and must be
    # unconditional — not swallowed by any surrounding rescue.
    def on_repeated_crash
      @on_repeated_crash ||= -> { java.lang.System.exit(1) }
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

    # Bounded, non-blocking write of the whole message using a monotonic
    # deadline. Returns :ok when fully written or :timeout when the write
    # deadline elapses. Lets Errno::EPIPE/ECONNRESET propagate to the caller so
    # each caller can decide how a peer-close is counted. Writes the original
    # string on the first pass (offset 0) so a response that fits in one write
    # is never copied (NEW-3).
    def write_all(connection, message)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @config.write_timeout
      offset   = 0
      total    = message.bytesize

      while offset < total
        chunk   = offset.zero? ? message : message.byteslice(offset, total - offset)
        written = connection.write_nonblock(chunk, exception: false)
        if written == :wait_writable
          time_left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return :timeout if time_left <= 0 || connection.wait_writable(time_left).nil?
        else
          offset += written
        end
      end
      :ok
    end

    # Write the full success response. Returns true on success, false if the
    # write timed out or the peer closed. Preserves the prior metric behavior:
    # a write timeout is recorded as an error here (record_outcome is skipped by
    # serve on a false return); a peer-close mid-write is not alarmed on.
    #
    # NOTE: JRuby raises Errno::EPIPE from write_nonblock even with
    # exception: false when the peer closes; we rescue it here.
    def write_response(connection, response)
      case write_all(connection, response)
      when :ok
        true
      else # :timeout
        @logger.warn('write timeout for client; abandoning connection')
        @metrics.record_error
        false
      end
    rescue Errno::EPIPE, Errno::ECONNRESET
      false
    end

    # Write an early-exit error response (read timeout / request too long)
    # through the same bounded writer so a non-reading client cannot wedge the
    # worker (L5). Best-effort: the client may already be gone. The outcome is
    # an error regardless of how the write ends, so record_error fires exactly
    # once via ensure.
    def write_read_error(connection, message)
      write_all(connection, message)
    rescue IOError, Errno::EPIPE, Errno::ECONNRESET
      nil
    ensure
      @metrics.record_error
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
        @logger.info("examine path=#{request.inspect} outcome=#{outcome} duration_ms=#{duration_ms}")
      end
    end

    # Create the socket's parent directory 0700 if missing, then (only for the
    # /tmp/fits-<uid> fallback) verify a PRE-EXISTING dir is safe. mkdir_p sets
    # the mode only on creation, so a squatted /tmp/fits-<uid> would otherwise
    # be trusted silently. We run unprivileged and cannot repair a dir owned by
    # someone else, so we refuse to start (loud, supervisor-visible) rather than
    # bind inside an attacker-controlled directory. The XDG/systemd runtime dir
    # and an explicit FITS_SOCKET_PATH are exempt: they are platform-owned or
    # operator-chosen and are frequently not 0700 (e.g. /run/fits is 0755).
    def ensure_socket_dir
      dir = File.dirname(socket_path)
      FileUtils.mkdir_p(dir, mode: 0o700)
      verify_socket_dir!(dir) if @config.default_tmpdir_socket?
    end

    # Fail closed if the tmpdir-fallback socket dir is not a real directory
    # owned by us with mode 0700. lstat (not stat) so a symlinked dir is
    # rejected rather than followed.
    def verify_socket_dir!(dir)
      stat = File.lstat(dir)
      reason =
        if stat.symlink? || !stat.directory?
          'not a directory'
        elsif stat.uid != Process.uid
          "owned by uid #{stat.uid}, not #{Process.uid}"
        elsif (stat.mode & 0o777) != 0o700
          format('mode %04o, expected 0700', stat.mode & 0o777)
        end
      return unless reason

      raise "refusing to use socket dir #{dir}: #{reason}"
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
