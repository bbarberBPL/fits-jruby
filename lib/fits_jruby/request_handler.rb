# frozen_string_literal: true

require 'json'

module FitsJruby
  # Pure protocol logic: turns a raw request line into a response string.
  # Knows nothing about sockets or threads.
  class RequestHandler
    STATS_COMMAND = 'STATS'

    def initialize(examiner:, metrics:)
      @examiner = examiner
      @metrics = metrics
    end

    def handle(raw_request)
      request = raw_request.to_s.strip
      return @metrics.snapshot.to_json if request == STATS_COMMAND
      return 'ERROR: empty request' if request.empty?

      error = validate_path(request)
      return error if error

      examine(request)
    end

    private

    def validate_path(path)
      return "ERROR: path must be absolute: #{path}" unless path.start_with?('/')
      return "ERROR: no such file: #{path}" unless File.exist?(path)
      return "ERROR: not a regular file: #{path}" unless File.file?(path)
      return "ERROR: not readable: #{path}" unless File.readable?(path)

      nil
    end

    def examine(path)
      @examiner.examine(path)
    rescue StandardError => e
      "ERROR: examination failed: #{e.message}"
    end
  end
end
