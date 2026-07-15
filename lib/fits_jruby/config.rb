# frozen_string_literal: true

module FitsJruby
  # Reads and validates server configuration from environment variables.
  class Config
    class Error < StandardError; end

    DEFAULT_SOCKET_PATH    = '/tmp/fits.sock'
    DEFAULT_QUEUE_CAPACITY = 64
    DEFAULT_LOG_LEVEL      = :info
    DEFAULT_READ_TIMEOUT   = 5
    DEFAULT_WRITE_TIMEOUT  = 30
    VALID_LOG_LEVELS       = %i[debug info warn error].freeze

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
      integer_env('FITS_QUEUE_CAPACITY', DEFAULT_QUEUE_CAPACITY, 'queue capacity')
    end

    def read_timeout
      integer_env('FITS_READ_TIMEOUT', DEFAULT_READ_TIMEOUT, 'read timeout')
    end

    def write_timeout
      integer_env('FITS_WRITE_TIMEOUT', DEFAULT_WRITE_TIMEOUT, 'write timeout')
    end

    def log_level
      @env.fetch('FITS_LOG_LEVEL', DEFAULT_LOG_LEVEL.to_s).downcase.to_sym
    end

    def validate!
      validate_fits_home!
      validate_log_level!
      validate_positive!(queue_capacity, 'queue capacity')
      validate_positive!(read_timeout, 'read timeout')
      validate_positive!(write_timeout, 'write timeout')
      self
    end

    private

    # Parses an integer env var, converting parse failures into Config::Error
    # with a label-specific message (e.g. "invalid queue capacity: ...").
    def integer_env(key, default, label)
      Integer(@env.fetch(key, default))
    rescue ArgumentError, TypeError
      raise Error, "invalid #{label}: #{@env[key]}"
    end

    def validate_positive!(value, label)
      raise Error, "invalid #{label}: must be positive" if value <= 0
    end

    def validate_fits_home!
      raise Error, 'FITS_HOME must be set' if fits_home.nil? || fits_home.empty?

      return if Dir.exist?(File.join(fits_home, 'lib'))

      raise Error, "FITS_HOME (#{fits_home}) must contain a lib/ directory"
    end

    def validate_log_level!
      return if VALID_LOG_LEVELS.include?(log_level)

      raise Error, "invalid log level: #{log_level} (expected one of #{VALID_LOG_LEVELS.join(', ')})"
    end
  end
end
