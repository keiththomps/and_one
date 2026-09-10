# frozen_string_literal: true

require_relative "sql_lexer"

module AndOne
  # Applied before retaining samples, including manually constructed detections.
  module CapturePolicy
    MAX_SAMPLES = 5
    MAX_SQL_BYTES = 2048
    MAX_FRAMES = 20
    MAX_FRAME_BYTES = 256

    # Bounded snapshots retain the commonly used Backtrace::Location accessors.
    Location = Struct.new(:text) do
      def to_s
        text
      end

      def path
        text.split(/:\d+/, 2).first
      end
      alias_method :absolute_path, :path

      def lineno
        text[/:(\d+)/, 1].to_i
      end
    end

    module_function

    def raw?
      AndOne.respond_to?(:capture_mode) && AndOne.capture_mode == :raw
    end

    def sql(value, adapter: nil)
      text = value.to_s
      text = SqlLexer.new(text, adapter: adapter).redacted unless raw?
      bounded(text, MAX_SQL_BYTES)
    rescue ArgumentError
      "[SQL redacted: invalid encoding]"
    end

    def frames(values)
      indexed = values.map(&:to_s).each_with_index.to_a
      application, internal = indexed.partition { |frame, _index| application_frame?(frame) }
      (application + internal).first(MAX_FRAMES).sort_by(&:last).map do |text, _index|
        unless raw?
          root = defined?(Rails) && Rails.respond_to?(:root) && Rails.root ? Rails.root.to_s : Dir.pwd
          text = text.delete_prefix("#{root}/")
          text = text.sub(%r{\A/.*?/(app|lib|test|spec|gems|ruby)/}, '\1/')
          text = File.basename(text) if text.start_with?("/")
        end
        bounded(text, MAX_FRAME_BYTES)
      end
    end

    def application_frame?(frame)
      !frame.match?(%r{(?:\A|/)(?:gems|ruby)/|lib/and_one/|\A<internal:|\(eval\)})
    end

    def bounded(value, bytes)
      value.encode("UTF-8", invalid: :replace, undef: :replace).byteslice(0, bytes).scrub("").freeze
    end
  end
end
