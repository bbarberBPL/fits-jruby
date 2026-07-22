# frozen_string_literal: true

require 'tmpdir'

module FitsJruby
  # Reads and validates server configuration from environment variables.
  class Config
    class Error < StandardError; end

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
      explicit = @env['FITS_SOCKET_PATH']
      return explicit if explicit && !explicit.empty?

      default_socket_path
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

    # Optional path-confinement allowlist. A colon-separated list of absolute
    # directory paths (like PATH). Empty/unset means no confinement (default).
    def allowed_roots
      @env.fetch('FITS_ALLOWED_ROOTS', '').split(File::PATH_SEPARATOR).reject(&:empty?)
    end

    def validate!
      validate_fits_home!
      validate_log_level!
      validate_positive!(queue_capacity, 'queue capacity')
      validate_positive!(read_timeout, 'read timeout')
      validate_positive!(write_timeout, 'write timeout')
      validate_allowed_roots!
      self
    end

    private

    # Per-user socket path so the default is not a shared, predictable path on
    # /tmp (which any local user could pre-create/squat). Prefers the systemd
    # per-user runtime dir when present; otherwise a per-uid subdir of the
    # system temp dir. SocketServer#start creates the parent dir 0700.
    def default_socket_path
      xdg = @env['XDG_RUNTIME_DIR']
      return "#{xdg}/fits.sock" if xdg && !xdg.empty?

      "#{Dir.tmpdir}/fits-#{Process.uid}/fits.sock"
    end

    # Parses an integer env var as base-10 (so "010" is 10, not octal 8),
    # converting parse failures into Config::Error with a label-specific
    # message. The default is an Integer and passed through as-is because
    # Integer(int, 10) raises "base specified for non string value".
    def integer_env(key, default, label)
      raw = @env.fetch(key, default)
      raw.is_a?(Integer) ? raw : Integer(raw, 10)
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

    # Fail fast on a misconfigured allowlist: a typo'd root that silently allows
    # nothing (or everything) is a security footgun.
    def validate_allowed_roots!
      allowed_roots.each do |root|
        raise Error, "allowed root must be absolute: #{root}" unless root.start_with?('/')
        raise Error, "allowed root must be a directory: #{root}" unless Dir.exist?(root)
      end
    end
  end
end
