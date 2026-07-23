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

      target, error = resolve_target(request)
      return error if error

      examine(target)
    end

    private

    # Validates the request and returns [examine_target, error]. Exactly one of
    # the two is non-nil. When no allowlist is configured (default, off) the path
    # is unconfined and returned as-is with NO realpath resolution. When an
    # allowlist is configured the path is canonicalized with File.realpath EXACTLY
    # ONCE; that single canonical value is both boundary-checked and returned as
    # the examine target, so the validated path and the opened path are identical
    # (no symlink-swap window between two realpath calls). realpath resolves
    # symlinks and "..". A SystemCallError (ENOENT/ELOOP/EACCES/ENOTDIR/...) is
    # treated as not allowed (fail closed).
    def resolve_target(path)
      stat_error = stat_check(path)
      return [nil, stat_error] if stat_error
      return [path, nil] if @allowed_roots.empty?

      real = File.realpath(path)
      return [nil, "ERROR: path not allowed: #{path}"] unless @allowed_roots.any? { |root| under_root?(real, root) }

      [real, nil]
    rescue SystemCallError, ArgumentError
      # SystemCallError: ENOENT/ELOOP/EACCES/... → not allowed (fail closed).
      # ArgumentError: File.* rejecting the argument (e.g. embedded NUL) — must
      # also fail closed rather than crash the worker.
      [nil, "ERROR: path not allowed: #{path}"]
    end

    # Returns an error string if the path fails basic file-stat checks, else nil.
    def stat_check(path)
      return "ERROR: path must be absolute: #{path}" unless path.start_with?('/')
      # Reject a NUL byte before any File.* call: File.exist?/File.file? raise
      # ArgumentError ("string contains null byte") on it, which is not a
      # SystemCallError and would otherwise escape the fail-closed rescue.
      return "ERROR: path not allowed: #{path}" if path.include?("\x00")
      return "ERROR: no such file: #{path}" unless File.exist?(path)
      return "ERROR: not a regular file: #{path}" unless File.file?(path)
      return "ERROR: not readable: #{path}" unless File.readable?(path)

      nil
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
