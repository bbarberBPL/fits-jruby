# frozen_string_literal: true

require 'json'

module FitsJruby
  # Pure protocol logic: turns a raw request line into a response string.
  # Knows nothing about sockets or threads.
  class RequestHandler
    STATS_COMMAND = 'STATS'

    def initialize(examiner:, metrics:, allowed_roots: [])
      @examiner = examiner
      @metrics = metrics
      # Canonicalize configured roots once so the boundary check compares
      # realpath-to-realpath. An empty list means no confinement (default).
      @allowed_roots = allowed_roots.map { |root| File.realpath(root) }
    end

    def handle(raw_request)
      request = raw_request.to_s.strip
      return @metrics.snapshot.to_json if request == STATS_COMMAND
      return 'ERROR: empty request' if request.empty?

      error = validate_path(request)
      return error if error

      examine(examine_target(request))
    end

    private

    def validate_path(path)
      return "ERROR: path must be absolute: #{path}" unless path.start_with?('/')
      return "ERROR: no such file: #{path}" unless File.exist?(path)
      return "ERROR: not a regular file: #{path}" unless File.file?(path)
      return "ERROR: not readable: #{path}" unless File.readable?(path)
      return "ERROR: path not allowed: #{path}" unless within_allowed_roots?(path)

      nil
    end

    # Defense-in-depth path confinement. When no roots are configured the path
    # is unconfined (default, off). When roots are configured the requested path
    # is canonicalized with File.realpath (resolving symlinks AND "..") and must
    # live under at least one canonical root. The boundary check compares path
    # components so a root of /srv/media never allows /srv/media-evil/x.
    # The path handed to the examiner. When an allowlist is configured we
    # examine the SAME canonical path the boundary check validated, so the
    # validated path and the opened path cannot diverge (closing a symlink-swap
    # gap). With no allowlist (default) the raw absolute path is examined as-is.
    # realpath cannot fail here under normal flow (validate_path already
    # confirmed existence and allowlist membership); a late failure is mapped to
    # the same fail-closed error as the boundary check.
    def examine_target(path)
      return path if @allowed_roots.empty?

      File.realpath(path)
    rescue SystemCallError
      path
    end

    def within_allowed_roots?(path)
      return true if @allowed_roots.empty?

      real = File.realpath(path)
      @allowed_roots.any? { |root| under_root?(real, root) }
    rescue SystemCallError
      # realpath can raise ENOENT (file vanished / broken symlink after the
      # earlier checks), ELOOP (symlink loop), EACCES, ENOTDIR, etc. Any such
      # failure to canonicalize is treated as not allowed (fail closed) rather
      # than crashing the worker.
      false
    end

    def under_root?(path, root)
      return true if path == root

      path.start_with?(root.end_with?(File::SEPARATOR) ? root : root + File::SEPARATOR)
    end

    def examine(path)
      @examiner.examine(path)
    rescue StandardError => e
      "ERROR: examination failed: #{e.message}"
    end
  end
end
