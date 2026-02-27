# frozen_string_literal: true

require "json"

module AndOne
  # Formats N+1 detections as structured JSON for log aggregation services
  # (Datadog, Splunk, New Relic, etc.).
  #
  # Usage:
  #   AndOne.json_logging = true
  #
  # Or use directly:
  #   formatter = AndOne::JsonFormatter.new
  #   formatter.format(detections) # => JSON string
  #
  # Each detection becomes a JSON object with:
  #   - event: "n_plus_one_detected"
  #   - table, fingerprint, query_count, sample_query
  #   - origin, fix_location, suggestion
  #   - timestamp, severity
  #
  class JsonFormatter
    def initialize(backtrace_cleaner: nil)
      @backtrace_cleaner = backtrace_cleaner
    end

    # Returns a JSON string containing an array of detection objects.
    # When there's a single detection, returns just the object (not wrapped in array).
    def format(detections)
      entries = detections.map { |d| format_detection(d) }
      entries.size == 1 ? JSON.generate(entries.first) : JSON.generate(entries)
    end

    # Returns an array of hashes (useful for structured logging integrations
    # that accept hashes directly, e.g., Rails tagged logging or Semantic Logger).
    def format_hashes(detections)
      detections.map { |d| format_detection(d) }
    end

    private

    def format_detection(detection)
      suggestion = resolve_suggestion(detection)

      entry = {
        event: "n_plus_one_detected",
        severity: "warning",
        timestamp: Time.now.utc.iso8601(3),
        table: detection.table_name,
        fingerprint: detection.fingerprint,
        query_count: detection.count,
        sample_query: detection.sample_query,
        origin: format_frame(detection.origin_frame),
        fix_location: format_frame(detection.fix_location),
        backtrace: clean_backtrace(detection.raw_caller_strings).first(10)
      }

      if suggestion&.actionable?
        entry[:suggestion] = {
          association: suggestion.association_name.to_s,
          parent_model: suggestion.parent_model&.name,
          fix: suggestion.fix_hint,
          loading_strategy: suggestion.loading_strategy&.to_s
        }
      end

      entry
    end

    def resolve_suggestion(detection)
      AssociationResolver.resolve(detection, detection.raw_caller_strings)
    rescue StandardError
      nil
    end

    def clean_backtrace(backtrace)
      if @backtrace_cleaner
        @backtrace_cleaner.clean(backtrace)
      else
        backtrace
      end
    end

    def format_frame(frame)
      return nil unless frame

      frame
        .sub(%r{.*/app/}, "app/")
        .sub(%r{.*/lib/}, "lib/")
        .sub(%r{.*/test/}, "test/")
        .sub(%r{.*/spec/}, "spec/")
    end
  end
end
