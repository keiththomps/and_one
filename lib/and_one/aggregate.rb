# frozen_string_literal: true

module AndOne
  # Tracks unique N+1 detections across requests/jobs in a server session.
  # In aggregate mode, each unique N+1 (by fingerprint) is only reported once.
  # Subsequent occurrences are silently counted.
  #
  # Usage:
  #   AndOne.aggregate_mode = true
  #
  # The aggregate can be queried at any time:
  #   AndOne.aggregate.summary   # => formatted string
  #   AndOne.aggregate.detections # => { fingerprint => { detection:, count:, first_seen_at: } }
  #   AndOne.aggregate.reset!
  #
  class Aggregate
    Entry = Struct.new(:detection, :occurrences, :first_seen_at, :last_seen_at, keyword_init: true)

    def initialize
      @mutex = Mutex.new
      @entries = {}
    end

    # Record a detection. Returns true if this is a NEW unique detection
    # (first time seeing this fingerprint), false if it's a repeat.
    def record(detection)
      fp = detection.fingerprint

      @mutex.synchronize do
        if @entries.key?(fp)
          @entries[fp].occurrences += 1
          @entries[fp].last_seen_at = Time.now
          false
        else
          @entries[fp] = Entry.new(
            detection: detection,
            occurrences: 1,
            first_seen_at: Time.now,
            last_seen_at: Time.now
          )
          true
        end
      end
    end

    def detections
      @mutex.synchronize { @entries.dup }
    end

    def size
      @mutex.synchronize { @entries.size }
    end

    def empty?
      @mutex.synchronize { @entries.empty? }
    end

    def reset!
      @mutex.synchronize { @entries.clear }
    end

    def summary
      @mutex.synchronize do
        return "No N+1 queries detected this session." if @entries.empty?

        lines = []
        lines << ""
        lines << "🏀 AndOne Session Summary: #{@entries.size} unique N+1 pattern#{'s' if @entries.size != 1}"
        lines << "─" * 60

        @entries.each_with_index do |(fp, entry), i|
          det = entry.detection
          lines << "  #{i + 1}) #{det.table_name || 'unknown'} — #{entry.occurrences} occurrence#{'s' if entry.occurrences != 1}"
          lines << "     #{det.sample_query[0, 120]}"
          lines << "     origin: #{det.origin_frame}" if det.origin_frame
          lines << "     fingerprint: #{fp}"
          lines << ""
        end

        lines << "─" * 60
        lines.join("\n")
      end
    end
  end
end
