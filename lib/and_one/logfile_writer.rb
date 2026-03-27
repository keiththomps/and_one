# frozen_string_literal: true

require "json"
require "fileutils"

module AndOne
  # Buffers N+1 detections in memory (deduplicated by fingerprint) and writes
  # them to a log file on process exit.  Handles parallel workers (forked test
  # processes, Puma cluster, etc.) by using file-level locking so all workers
  # safely append.  Truncation of stale data is handled at boot in the railtie,
  # before workers fork.
  class LogfileWriter
    # Clear stale findings from a previous boot.  Called once in the railtie
    # before workers fork so every worker starts with a clean file.
    def self.truncate!(path)
      File.truncate(path, 0) if path && File.exist?(path)
    end

    def initialize(path:, format: :text)
      @path = path
      @format = format
      @mutex = Mutex.new
      @entries = {}
    end

    # Accept an array of Detection objects; deduplicate by fingerprint.
    def record(detections)
      @mutex.synchronize do
        detections.each do |d|
          @entries[d.fingerprint] ||= d
        end
      end
    end

    # Format all buffered entries and write to the log file with locking.
    def flush!
      entries = @mutex.synchronize do
        snapshot = @entries.values
        @entries = {}
        snapshot
      end
      return if entries.empty?

      output = format_entries(entries)
      FileUtils.mkdir_p(File.dirname(@path))

      File.open(@path, File::RDWR | File::CREAT, 0o644) do |f|
        f.flock(File::LOCK_EX)
        f.seek(0, IO::SEEK_END)
        f.write("\n") if f.size.positive?
        f.write(output)
        f.flock(File::LOCK_UN)
      end
    end

    private

    def format_entries(entries)
      case @format
      when :json
        format_json(entries)
      else
        format_text(entries)
      end
    end

    def format_text(entries)
      formatter = Formatter.new
      output = formatter.format(entries)
      output.gsub(/\e\[\d+(?:;\d+)*m/, "")
    end

    def format_json(entries)
      json_formatter = JsonFormatter.new
      hashes = json_formatter.format_hashes(entries)
      hashes.map { |h| JSON.generate(h) }.join("\n")
    end
  end
end
