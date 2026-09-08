# frozen_string_literal: true

module AndOne
  # Enforcement applies to every scan; output sinks only receive new findings.
  module Reporting
    private

    def report(detections)
      new_detections = detections.select { |detection| aggregate.record(detection) }
      report_new(new_detections) unless new_detections.empty?
      return unless raise_on_detect

      formatter = Formatter.new(backtrace_cleaner: backtrace_cleaner || default_backtrace_cleaner)
      raise NPlus1Error, "\n#{formatter.format(detections)}"
    end

    def report_new(detections)
      logfile_writer&.record(detections)
      cleaner = backtrace_cleaner || default_backtrace_cleaner
      message = Formatter.new(backtrace_cleaner: cleaner).format(detections)

      # Keep the existing first-occurrence callback and output contracts.
      @report_mutex.synchronize do
        if json_logging
          json_output = JsonFormatter.new(backtrace_cleaner: cleaner).format(detections)
          if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
            Rails.logger.warn(json_output)
          else
            warn(json_output)
          end
        end

        notifications_callback&.call(detections, message)
        report_annotations(detections) if ENV["GITHUB_ACTIONS"]
        return if raise_on_detect || json_logging

        Rails.logger.warn("\n#{message}") if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        warn("\n#{message}") if $stderr.tty?
      end
    end

    def report_annotations(detections)
      detections.each do |detection|
        file, line = parse_frame_location(detection.fix_location || detection.origin_frame)
        query_count = "#{detection.count} queries to `#{detection.table_name || "unknown"}`"
        if file
          hint = "Add `.includes(:#{suggest_association_name(detection)})` to fix."
          $stdout.puts "::warning file=#{file},line=#{line || 1}::N+1 detected: #{query_count}. #{hint}"
        else
          $stdout.puts "::warning ::N+1 detected: #{query_count}."
        end
      end
    end
  end
end
