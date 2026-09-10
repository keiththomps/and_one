# frozen_string_literal: true

require "json"
require "fileutils"

module AndOne
  # A bounded retry buffer. Reporting flushes after each scan; file locking
  # keeps cooperating processes' appends intact.
  class LogfileWriter
    MAX_PENDING = 1000

    # Explicit reset only. Booting another process must never truncate findings.
    def self.truncate!(path)
      return unless path && File.exist?(path)

      File.open(path, File::RDWR) do |file|
        file.flock(File::LOCK_EX)
        file.truncate(0)
      end
    end

    def initialize(path:, format: :text)
      @path = path
      @format = format
      @mutex = Mutex.new
      @entries = {}
    end

    # Accept an array of Detection objects; deduplicate by issue identity.
    def record(detections)
      @mutex.synchronize do
        additions = detections.to_h { |d| [d.issue_id, d] }
        if (@entries.keys | additions.keys).size > MAX_PENDING
          raise IOError, "AndOne logfile retry buffer full (#{MAX_PENDING} findings); flush before retrying"
        end

        @entries.merge!(additions) { |_key, existing, _new| existing }
      end
    end

    # Format all buffered entries and write to the log file with locking.
    def flush!
      @mutex.synchronize do
        return if @entries.empty?

        output = "#{format_entries(@entries.values)}\n"
        FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
        append(output)
        @entries.clear
      end
    end

    private

    def append(output)
      File.open(@path, File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        original_size = file.size
        begin
          if original_size.positive?
            file.seek(-1, IO::SEEK_END)
            output = "\n#{output}" unless file.read(1) == "\n"
          end
          file.seek(0, IO::SEEK_END)
          written = file.write(output)
          raise IOError, "Incomplete AndOne logfile write" unless written == output.bytesize

          file.flush
        rescue StandardError
          file.truncate(original_size)
          raise
        ensure
          file.flock(File::LOCK_UN)
        end
      end
    end

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
