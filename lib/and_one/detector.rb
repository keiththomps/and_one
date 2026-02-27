# frozen_string_literal: true

module AndOne
  # Subscribes to ActiveRecord SQL notifications and detects N+1 query patterns.
  # Each instance tracks queries for a single request/block scope.
  class Detector
    DEFAULT_ALLOW_LIST = [
      /active_record\/relation.*preload_associations/,
      /active_record\/validations\/uniqueness/
    ].freeze

    attr_reader :detections

    def initialize(allow_stack_paths: [], ignore_queries: [], min_n_queries: 2)
      @allow_stack_paths = allow_stack_paths
      @ignore_queries = ignore_queries
      @min_n_queries = min_n_queries

      # location_key => count
      @query_counter = Hash.new(0)
      # location_key => [sql, ...]
      @query_holder = Hash.new { |h, k| h[k] = [] }
      # location_key => caller_locations
      @query_callers = {}
      # location_key => additional metadata from AR notification
      @query_metadata = {}

      @detections = []

      subscribe
    end

    def finish
      unsubscribe
      analyze
      @detections
    end

    private

    def subscribe
      # IMPORTANT: The notification callback fires on whatever thread triggered the SQL,
      # NOT necessarily the thread that created this Detector. We must look up the
      # current thread's detector (via Thread.current) to avoid cross-thread contamination.
      # We store our object_id so the callback can verify it's writing to the correct instance.
      detector_id = object_id

      @subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        next unless AndOne.scanning? && !AndOne.paused?

        # Only record if the current thread's detector is THIS detector.
        # Under Puma, multiple Detectors may be subscribed simultaneously;
        # each must only process its own thread's queries.
        current_detector = Thread.current[:and_one_detector]
        next unless current_detector&.object_id == detector_id

        sql = payload[:sql]
        name = payload[:name]

        next if name == "SCHEMA"
        next if !sql.include?("SELECT")
        next if payload[:cached]
        next if current_detector.send(:ignored?, sql)

        current_detector.send(:record_query, sql, payload)
      end
    end

    def unsubscribe
      ActiveSupport::Notifications.unsubscribe(@subscriber) if @subscriber
      @subscriber = nil
    end

    def record_query(sql, payload)
      locations = caller_locations
      location_key = location_fingerprint(locations)

      @query_counter[location_key] += 1
      @query_holder[location_key] << sql

      # Only store caller on the second occurrence to save memory
      if @query_counter[location_key] >= 2
        @query_callers[location_key] = locations
        @query_metadata[location_key] ||= {
          connection_adapter: adapter_name,
          type_casted_binds: payload[:type_casted_binds]
        }
      end
    end

    def location_fingerprint(locations)
      # Build a hash from the call stack to group identical call paths
      key = 0
      locations.each do |loc|
        key = key ^ loc.path.hash ^ loc.lineno
      end
      key
    end

    def adapter_name
      ActiveRecord::Base.connection_db_config.adapter
    rescue
      "unknown"
    end

    def analyze
      @query_counter.each do |location_key, count|
        next if count < @min_n_queries

        queries = @query_holder[location_key]
        callers = @query_callers[location_key]
        metadata = @query_metadata[location_key] || {}

        next unless callers

        # Group by fingerprint to confirm they're actually the same query shape
        grouped = queries.group_by { |q| Fingerprint.generate(q) }
        repeated = grouped.values.select { |group| group.size >= @min_n_queries }

        next if repeated.empty?

        caller_strings = callers.map(&:to_s)
        all_allow = DEFAULT_ALLOW_LIST + @allow_stack_paths
        next if caller_strings.any? { |frame| all_allow.any? { |pattern| frame.match?(pattern) } }

        repeated.each do |query_group|
          @detections << Detection.new(
            queries: query_group,
            caller_locations: callers,
            count: query_group.size,
            adapter: metadata[:connection_adapter]
          )
        end
      end
    end

    def ignored?(sql)
      @ignore_queries.any? { |pattern| pattern === sql }
    end
  end
end
