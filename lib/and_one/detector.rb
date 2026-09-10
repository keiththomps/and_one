# frozen_string_literal: true

require_relative "read_statement"
require_relative "connection_context"

module AndOne
  # Counts query shapes within one execution context. SQL samples, callers and
  # connection metadata are retained once per group, not once per occurrence.
  class Detector
    DEFAULT_ALLOW_LIST = [
      %r{active_record/relation.*preload_associations},
      %r{active_record/validations/uniqueness}
    ].freeze
    SAMPLE_LIMIT = 5
    Group = Struct.new(:total, :queries, :callers, :metadata, :ignored, :query_cost, :fingerprint)

    attr_reader :detections

    def initialize(allow_stack_paths: [], ignore_queries: [], min_n_queries: 2, ignore_list: nil)
      @allow_stack_paths = DEFAULT_ALLOW_LIST + allow_stack_paths
      @ignore_queries = ignore_queries
      @min_n_queries = min_n_queries
      @ignore_list = ignore_list
      @groups = {}
      @detections = []
    end

    def finish
      analyze
      @detections
    end

    def record(payload = nil, duration_ms: nil, **attributes)
      # Preserve direct record(sql: ...) callers as well as notification hashes.
      payload ||= attributes
      sql = payload[:sql]
      return if payload[:name] == "SCHEMA" || payload[:cached] || payload[:async]
      return if @ignore_queries.any? { |pattern| pattern.match?(sql) }

      metadata = ConnectionContext.metadata(payload)
      return unless ReadStatement.eligible?(sql, adapter: metadata[:connection_adapter])

      record_query(sql, metadata, duration_ms)
    end

    private

    def analyze
      @detections = @groups.values.filter_map do |group|
        next if group.total < @min_n_queries || group.ignored

        Detection.new(
          queries: group.queries,
          caller_locations: group.callers,
          fingerprint: group.fingerprint,
          count: group.total,
          adapter: group.metadata[:connection_adapter],
          connection_id: group.metadata[:connection_id],
          query_cost: group.query_cost
        )
      end
    end

    def record_query(sql, metadata, duration_ms)
      locations = caller_locations
      key = [location_fingerprint(locations), metadata[:connection_id],
             Digest::SHA256.hexdigest(Fingerprint.generate(sql, adapter: metadata[:connection_adapter]))]
      group = @groups[key] ||= new_group(locations, metadata, sql)
      group.total += 1
      group.query_cost.record(duration_ms)
      # Query ignore rules historically inspect ALL occurrences. Evaluate before
      # dropping samples so a late literal match still suppresses the whole group.
      group.ignored ||= @ignore_list&.query_ignored?(sql)
      group.queries << CapturePolicy.sql(sql, adapter: metadata[:connection_adapter]) if group.queries.size < SAMPLE_LIMIT
    end

    def new_group(locations, metadata, sql)
      patterns = @allow_stack_paths + (AndOne.ignore_callers || [])
      ignored = locations.any? { |frame| patterns.any? { |pattern| frame.to_s.match?(pattern) } }
      ignored ||= @ignore_list&.callers_ignored?(locations.map(&:to_s))
      sample = Detection.new(queries: [sql], count: 1, adapter: metadata[:connection_adapter])
      Group.new(total: 0, queries: [], callers: CapturePolicy.frames(locations), metadata: metadata,
                ignored: ignored, query_cost: QueryCost.new, fingerprint: sample.fingerprint)
    end

    def location_fingerprint(locations)
      Digest::SHA256.hexdigest(locations.map { |loc| [loc.path, loc.lineno] }.to_json)
    end
  end
end
