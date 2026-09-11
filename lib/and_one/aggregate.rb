# frozen_string_literal: true

require "json"
require "fileutils"
require "time"
require_relative "aggregate_store"

module AndOne
  # Tracks unique N+1 detections across requests/jobs in a server session.
  # Each unique N+1 (by issue identity) is only reported once.
  # Subsequent occurrences are silently counted.
  #
  # Memory storage is the default. An explicit path selects shared JSON storage.
  # Both stores retain only a bounded least-recently-observed history.
  #
  # The aggregate can be queried at any time:
  #   AndOne.aggregate.summary    # => formatted string
  #   AndOne.aggregate.detections # => { issue_id => Entry }
  #   AndOne.aggregate.reset!
  #
  class Aggregate
    Entry = Struct.new(:detection, :occurrences, :first_seen_at, :last_seen_at, :query_cost)

    MAX_ENTRIES = 100
    MAX_SAMPLES = 5
    MAX_SQL_BYTES = 2048
    MAX_FRAMES = 20
    MAX_FRAME_BYTES = 256

    def initialize(path: nil, store: nil, strict: false)
      @store = store || (path ? AggregateStore::FileStore.new(path) : AggregateStore::Memory.new)
      @strict = strict
      @warning_mutex = Mutex.new
    end

    # Record a detection. Returns true if this is a NEW unique detection
    # (first time seeing this issue identity), false if it's a repeat.
    def record(detection) # rubocop:disable Naming/PredicateMethod -- public compatibility API
      record_many([detection]).include?(detection)
    end

    # One transaction per scan. On failure all findings remain reportable.
    def record_many(detections)
      safely(default: detections) do
        @store.transaction do |data|
          normalize_data!(data)
          detections.select { |detection| record_new?(data, detection) }
        end
      end
    end

    def detections
      safely(default: {}) do
        @store.transaction do |data|
          normalize_data!(data)
          data.transform_values { |entry| deserialize_entry(entry) }
        end
      end
    end

    def size
      detections.size
    end

    def empty?
      detections.empty?
    end

    def reset!
      safely(default: nil) { @store.reset! }
    end

    def summary
      entries = detections

      return "No repeated-query findings detected this session." if entries.empty?

      lines = []
      lines << ""
      lines << "🏀 AndOne Session Summary: #{entries.size} unique repeated-query issue#{"s" if entries.size != 1}"
      lines << ("─" * 60)

      entries.each_with_index do |(fp, entry), i|
        det = entry.detection
        lines << "  #{i + 1}) #{det.table_name || "unknown"} — #{entry.occurrences} occurrence#{"s" if entry.occurrences != 1}"
        lines << "     #{det.classification_label}"
        lines << "     #{det.sample_query[0, 120]}"
        lines << "     origin: #{det.origin_frame}" if det.origin_frame
        lines << "     fingerprint: #{det.fingerprint}"
        lines << "     issue_id: #{fp}"
        lines << ""
      end

      lines << ("─" * 60)
      lines.join("\n")
    end

    private

    def record_new?(data, detection)
      key = detection.issue_id
      existing = data.delete(key)
      now = Time.now.iso8601
      data[key] = if existing
                    existing.merge("occurrences" => existing.fetch("occurrences") + 1, "last_seen_at" => now,
                                   "query_cost" => merged_cost(existing, detection)&.to_h)
                  else
                    { "detection" => serialize_detection(detection), "occurrences" => 1,
                      "first_seen_at" => now, "last_seen_at" => now, "query_cost" => detection.query_cost&.to_h }
                  end
      data.shift while data.size > MAX_ENTRIES
      !existing
    end

    def normalize_data!(data)
      normalized = data.values.last(MAX_ENTRIES).to_h do |entry|
        detection = deserialize_entry(entry).detection
        raise IOError, "Invalid occurrence count" unless entry["occurrences"].is_a?(Integer) && entry["occurrences"].positive?

        bounded_entry = { "detection" => serialize_detection(detection), "occurrences" => entry["occurrences"],
                          "first_seen_at" => parse_time(entry["first_seen_at"])&.iso8601,
                          "last_seen_at" => parse_time(entry["last_seen_at"])&.iso8601,
                          "query_cost" => stored_cost(entry)&.to_h }
        [detection.issue_id, bounded_entry]
      end
      data.replace(normalized)
    end

    def stored_cost(entry)
      QueryCost.new(entry["query_cost"]) if entry["query_cost"]
    end

    def merged_cost(entry, detection)
      previous = stored_cost(entry)
      previous ? previous.merge(detection.query_cost) : detection.query_cost
    end

    def safely(default:)
      yield
    rescue StandardError => e
      raise if @strict

      @warning_mutex.synchronize do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if !@last_warning || now - @last_warning >= 60
          @last_warning = now
          warn "AndOne aggregate storage failed (#{e.class}); findings were not persisted"
        end
      end
      default
    end

    def bounded(value, bytes)
      value.to_s.encode("UTF-8", invalid: :replace, undef: :replace).byteslice(0, bytes).scrub("")
    end

    def serialize_detection(det)
      {
        "queries" => det.queries.first(MAX_SAMPLES).map { |sql| bounded(sql, MAX_SQL_BYTES) },
        "caller_strings" => det.raw_caller_strings.first(MAX_FRAMES).map { |frame| bounded(frame, MAX_FRAME_BYTES) },
        "count" => det.count,
        "kind" => det.kind,
        "confidence" => det.confidence,
        "query_cost" => det.query_cost&.to_h,
        "adapter" => det.adapter && bounded(det.adapter, 128),
        "fingerprint" => det.fingerprint,
        "issue_id" => det.issue_id,
        "connection_id" => det.connection_id && bounded(det.connection_id, 256)
      }
    end

    def deserialize_entry(entry_data)
      det_data = entry_data["detection"]
      det = Detection.new(
        queries: det_data["queries"],
        raw_caller_strings: det_data["caller_strings"],
        count: det_data["count"],
        kind: det_data["kind"],
        confidence: det_data["confidence"],
        adapter: det_data["adapter"],
        connection_id: det_data["connection_id"],
        issue_id: det_data["issue_id"],
        fingerprint: det_data["fingerprint"],
        query_cost: stored_cost(det_data)
      )
      Entry.new(
        detection: det,
        occurrences: entry_data["occurrences"],
        first_seen_at: parse_time(entry_data["first_seen_at"]),
        last_seen_at: parse_time(entry_data["last_seen_at"]),
        query_cost: stored_cost(entry_data)
      )
    end

    def parse_time(str)
      str ? Time.parse(str) : nil
    end
  end
end
