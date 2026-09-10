# frozen_string_literal: true

require "digest"
require "securerandom"
require "fileutils"

module AndOne
  # Development processes join a stable session; test boots get independent IDs.
  # The random default is allocated before forking, so preloaded workers join it.
  class Session
    RUN_ID = SecureRandom.hex(16).freeze

    def self.default_id(environment)
      ENV.fetch("AND_ONE_SESSION") { environment == "test" ? RUN_ID : "default" }
    end

    def initialize(root:, environment:, id:)
      @root = root
      @key = Digest::SHA256.hexdigest([environment, id].join("\0"))
      @mutex = Mutex.new
    end

    def path
      File.join(@root, @key)
    end

    # Keep a shared lease open for this process lifetime. Cleanup cannot remove
    # live sessions, including leases inherited by preloaded workers.
    def activate!
      @mutex.synchronize do
        return path if @lease && File.directory?(path)

        FileUtils.mkdir_p(@root, mode: 0o700)
        with_registry_lock do
          FileUtils.mkdir_p(path, mode: 0o700)
          @lease = File.new(File.join(path, "session.lock"), File::RDWR | File::CREAT, 0o600)
          @lease.flock(File::LOCK_SH)
          FileUtils.touch(File.join(path, "session.lock"))
        end
      end
      path
    end

    # Explicit maintenance only: inspect at most limit sessions. Call again for
    # large directories. No boot-time history deletion or unbounded directory scan.
    def cleanup!(older_than: 7 * 86_400, limit: 100)
      return 0 unless File.directory?(@root)
      raise ArgumentError, "positive cleanup limits required" unless older_than.positive? && limit.positive?

      removed = 0
      with_registry_lock do
        cleanup_names(limit).each do |name|
          next unless name.match?(/\A[0-9a-f]{64}\z/)

          directory = File.join(@root, name)
          next if File.symlink?(directory) || !File.directory?(directory)

          removed += 1 if remove_stale(directory, Time.now - older_than)
        end
      end
      removed
    end

    private

    def cleanup_names(limit)
      @cleanup_entries ||= Dir.each_child(@root)
      names = []
      limit.times { names << @cleanup_entries.next }
      names
    rescue StopIteration
      @cleanup_entries = nil
      names
    end

    def with_registry_lock
      File.open(File.join(@root, "sessions.lock"), File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        yield
      end
    end

    def remove_stale(directory, cutoff)
      File.open(File.join(directory, "session.lock"), File::RDWR | File::CREAT, 0o600) do |lease|
        return false unless lease.flock(File::LOCK_EX | File::LOCK_NB)

        # Directory mtime tracks aggregate renames; logfile mtime tracks appends.
        latest = [directory, *Dir.glob(File.join(directory, "{aggregate.json,findings.log,session.lock}"))]
                 .map { |file| File.mtime(file) }.max
        return false unless latest < cutoff

        FileUtils.rm_rf(directory)
        true
      end
    end
  end
end
