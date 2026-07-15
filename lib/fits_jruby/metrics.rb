# frozen_string_literal: true

module FitsJruby
  # Thread-safe counters and gauges describing server activity, plus a JVM
  # heap snapshot. Clock and heap reader are injectable for testing.
  class Metrics
    def self.default_clock
      -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    end

    def self.default_heap_reader
      lambda do
        require 'java'
        bean = java.lang.management.ManagementFactory.getMemoryMXBean
        usage = bean.getHeapMemoryUsage
        { used: usage.getUsed, max: usage.getMax }
      end
    end

    def initialize(clock: self.class.default_clock, heap_reader: self.class.default_heap_reader)
      @clock = clock
      @heap_reader = heap_reader
      @started_at = @clock.call
      @mutex = Mutex.new
      @success = 0
      @error = 0
      @queue_depth = 0
      @processing = false
    end

    def record_success
      @mutex.synchronize { @success += 1 }
    end

    def record_error
      @mutex.synchronize { @error += 1 }
    end

    def enqueue
      @mutex.synchronize { @queue_depth += 1 }
    end

    def dequeue
      @mutex.synchronize { @queue_depth -= 1 if @queue_depth.positive? }
    end

    def processing=(value)
      @mutex.synchronize { @processing = value }
    end

    def snapshot
      heap = @heap_reader.call
      @mutex.synchronize do
        {
          uptime_seconds: (@clock.call - @started_at).to_i,
          requests_total: @success + @error,
          requests_success: @success,
          requests_error: @error,
          queue_depth: @queue_depth,
          processing: @processing,
          heap_used_bytes: heap[:used],
          heap_max_bytes: heap[:max]
        }
      end
    end
  end
end
