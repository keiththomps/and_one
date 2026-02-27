# frozen_string_literal: true

module AndOne
  # Formats N+1 detections into readable, actionable output.
  class Formatter
    COLORS = {
      red: "\e[91m",
      yellow: "\e[93m",
      green: "\e[92m",
      cyan: "\e[96m",
      dim: "\e[2m",
      bold: "\e[1m",
      reset: "\e[0m"
    }.freeze

    SEPARATOR = "─" * 70

    def initialize(backtrace_cleaner: nil)
      @backtrace_cleaner = backtrace_cleaner
    end

    def format(detections)
      parts = []
      parts << ""
      parts << colorize(SEPARATOR, :red)
      parts << colorize(" 🏀 And One! #{detections.size} N+1 quer#{detections.size == 1 ? "y" : "ies"} detected", :red,
                        :bold)
      parts << colorize(SEPARATOR, :red)

      detections.each_with_index do |detection, i|
        parts << ""
        parts << format_detection(detection, i + 1)
      end

      parts << ""
      parts << colorize(SEPARATOR, :red)
      parts.join("\n")
    end

    private

    def format_detection(detection, index) # rubocop:disable Metrics
      lines = []
      cleaned_bt = clean_backtrace(detection.raw_caller_strings)

      # Header with count and fingerprint
      lines << colorize("  #{index}) #{detection.count}x repeated query on `#{detection.table_name || "unknown"}`",
                        :yellow, :bold)
      lines << colorize("     fingerprint: #{detection.fingerprint}", :dim)
      lines << ""

      # Sample query
      lines << colorize("  Query:", :cyan)
      lines << colorize("    #{truncate_query(detection.sample_query)}", :dim)
      lines << ""

      # Origin — where the N+1 is triggered
      if detection.origin_frame
        lines << colorize("  Origin (where the N+1 is triggered):", :cyan)
        lines << colorize("  → #{format_frame(detection.origin_frame)}", :yellow)
        lines << ""
      end

      # Fix location — where to add .includes
      if detection.fix_location && detection.fix_location != detection.origin_frame
        lines << colorize("  Fix here (where to add .includes):", :cyan)
        lines << colorize("  ⇒ #{format_frame(detection.fix_location)}", :green)
        lines << ""
      end

      # Abbreviated call stack
      lines << colorize("  Call stack:", :cyan)
      cleaned_bt.first(6).each_with_index do |frame, _fi|
        lines << colorize("    #{frame}", :dim)
      end
      lines << colorize("    ... (#{cleaned_bt.size - 6} more frames)", :dim) if cleaned_bt.size > 6
      lines << ""

      # Association suggestion
      suggestion = resolve_suggestion(detection, cleaned_bt)
      if suggestion&.actionable?
        lines << colorize("  💡 Suggestion:", :cyan, :bold)
        lines << colorize("    #{suggestion.fix_hint}", :green)
        lines << colorize("    #{suggestion.loading_strategy_hint}", :green) if suggestion.loading_strategy_hint
        lines << colorize("    #{suggestion.strict_loading_hint}", :dim) if suggestion.strict_loading_hint
      end

      # Ignore hint
      lines << ""
      lines << colorize("  To ignore, add to .and_one_ignore:", :dim)
      lines << colorize("    fingerprint:#{detection.fingerprint}", :dim)

      lines.join("\n")
    end

    def resolve_suggestion(detection, cleaned_backtrace)
      AssociationResolver.resolve(detection, cleaned_backtrace)
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
      # Strip common prefixes for readability
      frame
        .sub(%r{.*/app/}, "app/")
        .sub(%r{.*/lib/}, "lib/")
        .sub(%r{.*/test/}, "test/")
        .sub(%r{.*/spec/}, "spec/")
    end

    def truncate_query(sql, max_length: 200)
      return sql if sql.length <= max_length

      "#{sql[0...max_length]}..."
    end

    def colorize(text, *styles)
      return text unless $stdout.tty?

      prefix = styles.map { |s| COLORS[s] }.compact.join
      "#{prefix}#{text}#{COLORS[:reset]}"
    end
  end
end
