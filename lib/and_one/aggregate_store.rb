# frozen_string_literal: true

require "json"
require "fileutils"

module AndOne
  module AggregateStore
    # Stores implement transaction { |data| ... } and return the block result.
    # The facade owns retention; stores own synchronization and atomic commit.
    class Memory
      def initialize
        @data = {}
        @mutex = Mutex.new
      end

      def transaction
        @mutex.synchronize { yield @data }
      end

      def reset!
        transaction(&:clear)
      end
    end

    class FileStore
      MAX_BYTES = 4 * 1024 * 1024

      def initialize(path, require_existing: false)
        @require_existing = require_existing
        @session = path if path.respond_to?(:activate!)
        @path = @session ? @session.path : path
        @mutex = Mutex.new
      end

      def reset!
        transaction(reset: true, &:clear)
      end

      def transaction(reset: false)
        @mutex.synchronize do
          @session&.activate!
          FileUtils.mkdir_p(@path, mode: 0o700) unless @require_existing
          mode = @require_existing ? File::RDWR : File::RDWR | File::CREAT
          File.open(File.join(@path, "aggregate.lock"), mode, 0o600) do |lock|
            lock.flock(File::LOCK_EX)
            data = reset ? {} : read_data
            before = JSON.generate(data)
            result = yield data
            output = JSON.generate(data)
            write_data(output) if reset || before != output
            result
          end
        end
      end

      private

      def read_data
        path = File.join(@path, "aggregate.json")
        return {} if !@require_existing && !File.exist?(path)

        input = File.open(path, "rb") { |file| file.read(MAX_BYTES + 1) }
        raise IOError, "Aggregate exceeds byte limit" if input.bytesize > MAX_BYTES

        data = JSON.parse(input)
        raise IOError, "Invalid aggregate document" unless data.is_a?(Hash)

        data
      end

      def write_data(output)
        raise IOError, "Aggregate exceeds byte limit" if output.bytesize > MAX_BYTES

        path = File.join(@path, "aggregate.json")
        temporary = "#{path}.tmp"
        begin
          File.open(temporary, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
            written = file.write(output)
            raise IOError, "Incomplete aggregate write" unless written == output.bytesize

            file.flush
          end
          File.rename(temporary, path)
        ensure
          FileUtils.rm_f(temporary)
        end
      end
    end
  end
end
