# frozen_string_literal: true

require "json"
require "fileutils"
require "time"

module AndOne
  # Tracks unique N+1 detections across requests/jobs in a server session.
  # Each unique N+1 (by fingerprint) is only reported once.
  # Subsequent occurrences are silently counted.
  #
  # Data is stored on disk (JSON) so detections are shared across all Puma
  # workers in multi-process deployments. File locking ensures consistency.
  #
  # The aggregate can be queried at any time:
  #   AndOne.aggregate.summary    # => formatted string
  #   AndOne.aggregate.detections # => { fingerprint => Entry }
  #   AndOne.aggregate.reset!
  #
  class Aggregate
    Entry = Struct.new(:detection, :occurrences, :first_seen_at, :last_seen_at)

    def initialize(path: nil)
      @dir = path || default_dir
      @data_path = File.join(@dir, "aggregate.json")
      @lock_path = File.join(@dir, "aggregate.lock")
      @mutex = Mutex.new
      FileUtils.mkdir_p(@dir)
    end

    # Record a detection. Returns true if this is a NEW unique detection
    # (first time seeing this fingerprint), false if it's a repeat.
    def record(detection)
      fp = detection.fingerprint

      with_lock do
        data = read_data

        if data.key?(fp)
          data[fp]["occurrences"] += 1
          data[fp]["last_seen_at"] = Time.now.iso8601
          write_data(data)
          false
        else
          data[fp] = {
            "detection" => serialize_detection(detection),
            "occurrences" => 1,
            "first_seen_at" => Time.now.iso8601,
            "last_seen_at" => Time.now.iso8601
          }
          write_data(data)
          true
        end
      end
    end

    def detections
      with_lock do
        data = read_data
        data.each_with_object({}) do |(fp, entry_data), result|
          result[fp] = deserialize_entry(entry_data)
        end
      end
    end

    def size
      with_lock { read_data.size }
    end

    def empty?
      with_lock { read_data.empty? }
    end

    def reset!
      with_lock do
        FileUtils.rm_f(@data_path)
      end
    end

    def summary
      entries = detections

      return "No N+1 queries detected this session." if entries.empty?

      lines = []
      lines << ""
      lines << "🏀 AndOne Session Summary: #{entries.size} unique N+1 pattern#{"s" if entries.size != 1}"
      lines << ("─" * 60)

      entries.each_with_index do |(fp, entry), i|
        det = entry.detection
        lines << "  #{i + 1}) #{det.table_name || "unknown"} — #{entry.occurrences} occurrence#{"s" if entry.occurrences != 1}"
        lines << "     #{det.sample_query[0, 120]}"
        lines << "     origin: #{det.origin_frame}" if det.origin_frame
        lines << "     fingerprint: #{fp}"
        lines << ""
      end

      lines << ("─" * 60)
      lines.join("\n")
    end

    private

    def with_lock
      @mutex.synchronize do
        File.open(@lock_path, File::RDWR | File::CREAT) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end
    end

    def read_data
      return {} unless File.exist?(@data_path)

      JSON.parse(File.read(@data_path))
    rescue JSON::ParserError
      {}
    end

    def write_data(data)
      tmp_path = "#{@data_path}.tmp"
      File.write(tmp_path, JSON.generate(data))
      File.rename(tmp_path, @data_path)
    end

    def serialize_detection(det)
      {
        "queries" => det.queries,
        "caller_strings" => det.raw_caller_strings,
        "count" => det.count,
        "adapter" => det.adapter
      }
    end

    def deserialize_entry(entry_data)
      det_data = entry_data["detection"]
      det = Detection.new(
        queries: det_data["queries"],
        raw_caller_strings: det_data["caller_strings"],
        count: det_data["count"],
        adapter: det_data["adapter"]
      )
      Entry.new(
        detection: det,
        occurrences: entry_data["occurrences"],
        first_seen_at: parse_time(entry_data["first_seen_at"]),
        last_seen_at: parse_time(entry_data["last_seen_at"])
      )
    end

    def parse_time(str)
      str ? Time.parse(str) : nil
    end

    def default_dir
      if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
        Rails.root.join("tmp", "and_one").to_s
      else
        File.join(Dir.pwd, "tmp", "and_one")
      end
    end
  end
end
