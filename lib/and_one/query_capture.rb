# frozen_string_literal: true

module AndOne
  # Explicit physical-query measurement, independent of N+1 detection/reporting.
  # Captures only this fiber; nested measurements contribute to their parents.
  class QueryCapture
    MAX_LOCATIONS = 5
    MAX_LOCATION_BYTES = 300
    INTERNAL_PATH = File.expand_path(__dir__)

    attr_reader :count, :cached_count, :locations

    def initialize
      @count = 0
      @cached_count = 0
      @locations = []
    end

    def self.capture
      raise ArgumentError, "a workload block is required" unless block_given?

      previous = ExecutionContext[:and_one_query_captures]
      result = new
      ExecutionContext[:and_one_query_captures] = [*previous, result]
      begin
        yield
        result
      ensure
        ExecutionContext[:and_one_query_captures] = previous
      end
    end

    def self.validate_limit!(limit)
      return if limit.is_a?(Integer) && limit >= 0

      raise ArgumentError, "query limit must be a non-negative Integer"
    end

    def record(payload)
      return if payload[:name] == "SCHEMA" || payload[:sql].to_s.empty?

      if payload[:cached]
        @cached_count += 1
      else
        @count += 1
        record_location if locations.size < MAX_LOCATIONS
      end
    end

    def summary
      "#{count} executed queries (#{cached_count} cache hits excluded); locations: #{locations.join(", ")}"
    end

    private

    def record_location
      frame = caller_locations.find do |location|
        path = location.absolute_path || location.path
        path && !path.start_with?(INTERNAL_PATH) && !path.include?("/gems/") && !path.start_with?("<internal:")
      end
      return unless frame

      location = "#{frame.path}:#{frame.lineno}".byteslice(0, MAX_LOCATION_BYTES).scrub
      locations << location unless locations.include?(location)
    end
  end

  class QueryGrowth
    attr_reader :small, :large, :max_growth

    def initialize(small:, large:, max_growth:)
      QueryCapture.validate_limit!(max_growth)
      raise ArgumentError, "small and large workloads must respond to call" unless small.respond_to?(:call) && large.respond_to?(:call)

      @max_growth = max_growth
      @small = QueryCapture.capture { small.call }
      @large = QueryCapture.capture { large.call }
    end

    def growth
      large.count - small.count
    end

    def within_limit?
      growth <= max_growth
    end

    def summary
      "query growth #{growth} (maximum #{max_growth}); small: #{small.summary}; large: #{large.summary}"
    end
  end
end
