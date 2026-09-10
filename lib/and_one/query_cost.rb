# frozen_string_literal: true

module AndOne
  # Constant-space observed SQL notification costs; never an estimate of savings.
  class QueryCost
    FIELDS = %w[query_count timed_query_count total_duration_ms min_duration_ms max_duration_ms occurrences].freeze

    attr_reader(*FIELDS)

    def initialize(data = {})
      @query_count = data.fetch("query_count", 0)
      @timed_query_count = data.fetch("timed_query_count", 0)
      @total_duration_ms = data.fetch("total_duration_ms", 0.0)
      @min_duration_ms = data["min_duration_ms"]
      @max_duration_ms = data["max_duration_ms"]
      @occurrences = data.fetch("occurrences", 1)
    end

    def record(duration_ms)
      @query_count += 1
      return unless duration_ms.is_a?(Numeric) && duration_ms.finite? && duration_ms >= 0

      @timed_query_count += 1
      @total_duration_ms += duration_ms
      @min_duration_ms = [min_duration_ms, duration_ms].compact.min
      @max_duration_ms = [max_duration_ms, duration_ms].compact.max
    end

    def merge(other)
      return self unless other

      self.class.new(
        "query_count" => query_count + other.query_count,
        "timed_query_count" => timed_query_count + other.timed_query_count,
        "total_duration_ms" => total_duration_ms + other.total_duration_ms,
        "min_duration_ms" => [min_duration_ms, other.min_duration_ms].compact.min,
        "max_duration_ms" => [max_duration_ms, other.max_duration_ms].compact.max,
        "occurrences" => occurrences + other.occurrences
      )
    end

    def to_h
      FIELDS.to_h { |field| [field, public_send(field)] }.merge(
        "mean_duration_ms" => timed_query_count.positive? ? total_duration_ms / timed_query_count : nil,
        "cached_queries" => "excluded"
      )
    end
  end
end
