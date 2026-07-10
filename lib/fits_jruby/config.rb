# frozen_string_literal: true

module FitsJruby
  # Reads and validates server configuration from environment variables.
  class Config
    class Error < StandardError; end

    DEFAULT_SOCKET_PATH = '/tmp/fits.sock'
    DEFAULT_QUEUE_CAPACITY = 64
    DEFAULT_LOG_LEVEL = :info
    VALID_LOG_LEVELS = %i[debug info warn error].freeze

    def initialize(env = ENV)
      @env = env
    end

    def fits_home
      @env['FITS_HOME']
    end

    def socket_path
      @env.fetch('FITS_SOCKET_PATH', DEFAULT_SOCKET_PATH)
    end

    def queue_capacity
      Integer(@env.fetch('FITS_QUEUE_CAPACITY', DEFAULT_QUEUE_CAPACITY))
    rescue ArgumentError, TypeError
      raise Error, "invalid queue capacity: #{@env['FITS_QUEUE_CAPACITY']}"
    end

    def log_level
      @env.fetch('FITS_LOG_LEVEL', DEFAULT_LOG_LEVEL.to_s).downcase.to_sym
    end

    def validate!
      raise Error, 'FITS_HOME must be set' if fits_home.nil? || fits_home.empty?

      unless Dir.exist?(File.join(fits_home, 'lib'))
        raise Error, "FITS_HOME (#{fits_home}) must contain a lib/ directory"
      end

      unless VALID_LOG_LEVELS.include?(log_level)
        raise Error, "invalid log level: #{log_level} (expected one of #{VALID_LOG_LEVELS.join(', ')})"
      end

      validate_queue_capacity!

      self
    end

    private

    def validate_queue_capacity!
      capacity = queue_capacity
      raise Error, 'invalid queue capacity: must be positive' if capacity <= 0
    rescue Error
      raise
    rescue ArgumentError, TypeError
      raise Error, "invalid queue capacity: #{@env['FITS_QUEUE_CAPACITY']}"
    end
  end
end
