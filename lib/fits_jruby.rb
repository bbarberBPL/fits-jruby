# frozen_string_literal: true

require 'logger'
require_relative 'fits_jruby/config'
require_relative 'fits_jruby/metrics'
require_relative 'fits_jruby/request_handler'
require_relative 'fits_jruby/fits_examiner'
require_relative 'fits_jruby/socket_server'

module FitsJruby
  # Assemble the server object graph and return the SocketServer. Pure
  # assembly: no config validation, no signal traps, no blocking. The examiner
  # is injectable so the wiring can be unit-tested without loading FITS/JVM.
  def self.build_server(config: Config.new, examiner: nil)
    examiner ||= FitsExaminer.new(config.fits_home)
    metrics = Metrics.new
    logger = build_logger(config.log_level)
    handler = RequestHandler.new(
      examiner: examiner,
      metrics: metrics,
      allowed_roots: config.allowed_roots,
      logger: logger
    )
    SocketServer.new(config: config, handler: handler, metrics: metrics, logger: logger)
  end

  # Build the shared server logger. SocketServer keeps its own equivalent
  # fallback for direct construction (e.g. specs) when no logger is injected;
  # the small overlap is intentional so neither construction path can produce a
  # nil logger.
  def self.build_logger(level)
    logger = Logger.new($stdout)
    logger.level = Logger.const_get(level.to_s.upcase)
    logger
  end

  # Entry point used by bin/fits-server: validate config, build the server,
  # install INT/TERM handlers for a clean shutdown, start, and block forever.
  # Never returns under normal operation.
  def self.run!(config: Config.new)
    config.validate!
    server = build_server(config: config)
    install_signal_traps(server)
    server.start
    sleep
  rescue Config::Error => e
    warn "configuration error: #{e.message}"
    exit 1
  end

  # Internal helper for run!; not part of the public API.
  def self.install_signal_traps(server)
    shutdown = proc do
      server.stop
      exit 0
    end
    Signal.trap('INT', &shutdown)
    Signal.trap('TERM', &shutdown)
  end
  private_class_method :install_signal_traps
end
