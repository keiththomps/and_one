# frozen_string_literal: true

module AndOne
  # Formats N+1 detections into readable, actionable output.
  class Formatter
    COLORS = {
      red: "\e[91m",
      yellow: "\e[93m",
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
      parts << colorize("#{SEPARATOR}", :red)
      parts << colorize(" 🏀 And One! #{detections.size} N+1 quer#{detections.size == 1 ? 'y' : 'ies'} detected", :red, :bold)
      parts << colorize("#{SEPARATOR}", :red)

      detections.each_with_index do |detection, i|
        parts << ""
        parts << format_detection(detection, i + 1)
      end

      parts << ""
      parts << colorize(SEPARATOR, :red)
      parts.join("\n")
    end

    private

    def format_detection(detection, index)
      lines = []
      cleaned_bt = clean_backtrace(detection.caller_locations.map(&:to_s))

      # Header
      lines << colorize("  #{index}) #{detection.count}x repeated query on `#{detection.table_name || 'unknown'}`", :yellow, :bold)
      lines << ""

      # Sample query
      lines << colorize("  Query:", :cyan)
      lines << colorize("    #{truncate_query(detection.sample_query)}", :dim)
      lines << ""

      # Call site
      lines << colorize("  Call stack:", :cyan)
      cleaned_bt.first(8).each_with_index do |frame, fi|
        prefix = fi == 0 ? "  → " : "    "
        color = fi == 0 ? :yellow : :dim
        lines << colorize("#{prefix}#{frame}", color)
      end
      lines << colorize("    ... (#{cleaned_bt.size - 8} more frames)", :dim) if cleaned_bt.size > 8

      # Try to resolve association and suggest fix
      suggestion = resolve_suggestion(detection, cleaned_bt)
      if suggestion&.actionable?
        lines << ""
        lines << colorize("  💡 Fix:", :cyan, :bold)
        lines << colorize("    #{suggestion.fix_hint}", :yellow)
        if suggestion.origin_frame
          lines << colorize("    at #{suggestion.origin_frame}", :dim)
        end
      end

      lines.join("\n")
    end

    def resolve_suggestion(detection, cleaned_backtrace)
      AssociationResolver.resolve(detection, cleaned_backtrace)
    rescue => e
      # Never let suggestion resolution break the output
      nil
    end

    def clean_backtrace(backtrace)
      if @backtrace_cleaner
        @backtrace_cleaner.clean(backtrace)
      else
        backtrace
      end
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
