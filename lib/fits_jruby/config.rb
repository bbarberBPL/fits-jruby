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
      Integer(@env.fetch('FITS_QUEUE_CAPACITY', DEFAULT_QUEUE_CAPACITY))
    rescue ArgumentError, TypeError
      raise Error, "invalid queue capacity: #{@env['FITS_QUEUE_CAPACITY']}"
    end

    def read_timeout
      Integer(@env.fetch('FITS_READ_TIMEOUT', DEFAULT_READ_TIMEOUT))
    rescue ArgumentError, TypeError
      raise Error, "invalid read timeout: #{@env['FITS_READ_TIMEOUT']}"
    end

    def write_timeout
      Integer(@env.fetch('FITS_WRITE_TIMEOUT', DEFAULT_WRITE_TIMEOUT))
    rescue ArgumentError, TypeError
      raise Error, "invalid write timeout: #{@env['FITS_WRITE_TIMEOUT']}"
    end

    def log_level
      @env.fetch('FITS_LOG_LEVEL', DEFAULT_LOG_LEVEL.to_s).downcase.to_sym
    end

    def validate!
      validate_fits_home!
      validate_log_level!
      validate_queue_capacity!
      validate_read_timeout!
      validate_write_timeout!
      self
    end

    private

    def validate_fits_home!
      raise Error, 'FITS_HOME must be set' if fits_home.nil? || fits_home.empty?

      return if Dir.exist?(File.join(fits_home, 'lib'))

      raise Error, "FITS_HOME (#{fits_home}) must contain a lib/ directory"
    end

    def validate_log_level!
      return if VALID_LOG_LEVELS.include?(log_level)

      raise Error, "invalid log level: #{log_level} (expected one of #{VALID_LOG_LEVELS.join(', ')})"
    end

    def validate_queue_capacity!
      capacity = queue_capacity
      raise Error, 'invalid queue capacity: must be positive' if capacity <= 0
    rescue Error
      raise
    rescue ArgumentError, TypeError
      raise Error, "invalid queue capacity: #{@env['FITS_QUEUE_CAPACITY']}"
    end

    def validate_read_timeout!
      timeout = read_timeout
      raise Error, 'invalid read timeout: must be positive' if timeout <= 0
    rescue Error
      raise
    rescue ArgumentError, TypeError
      raise Error, "invalid read timeout: #{@env['FITS_READ_TIMEOUT']}"
    end

    def validate_write_timeout!
      timeout = write_timeout
      raise Error, 'invalid write timeout: must be positive' if timeout <= 0
    rescue Error
      raise
    rescue ArgumentError, TypeError
      raise Error, "invalid write timeout: #{@env['FITS_WRITE_TIMEOUT']}"
    end
  end
end
