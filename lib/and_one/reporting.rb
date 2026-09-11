# frozen_string_literal: true

module AndOne
  # Enforcement applies to every scan; output sinks only receive new findings.
  module Reporting
    private

    def report(detections)
      new_detections = aggregate.record_many(detections)
      safely_deliver do
        writer = logfile_writer
        writer&.record(new_detections)
        writer&.flush!
      end
      safely_deliver { report_new(new_detections) } unless new_detections.empty?
      return unless raise_on_detect

      formatter = Formatter.new(backtrace_cleaner: backtrace_cleaner || default_backtrace_cleaner)
      raise NPlus1Error, "\n#{formatter.format(detections)}"
    end

    def report_new(detections)
      cleaner = backtrace_cleaner || default_backtrace_cleaner
      message = Formatter.new(backtrace_cleaner: cleaner).format(detections)

      # User code must never run under the non-reentrant output mutex.
      safely_deliver { notifications_callback&.call(detections, message) }

      @report_mutex.synchronize do
        if json_logging
          json_output = JsonFormatter.new(backtrace_cleaner: cleaner).format(detections)
          if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
            Rails.logger.warn(json_output)
          else
            warn(json_output)
          end
        end

        report_annotations(detections) if ENV["GITHUB_ACTIONS"]
        return if raise_on_detect || json_logging

        Rails.logger.warn("\n#{message}") if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        warn("\n#{message}") if $stderr.tty?
      end
    end

    # Sink failures are best-effort and must not suppress N+1 enforcement.
    # Emit at most one diagnostic per minute, without invoking application code.
    def safely_deliver
      yield
    rescue NPlus1Error
      raise
    rescue StandardError => e
      @report_mutex.synchronize do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if !@last_delivery_warning || now - @last_delivery_warning >= 60
          @last_delivery_warning = now
          warn "AndOne reporting failed (#{e.class}); logfile entries retained within retry-buffer limits"
        end
      end
    end

    def annotation_hint(detection)
      AssociationResolver.resolve(detection, detection.raw_caller_strings)&.fix_hint || "Inspect the call site."
    rescue StandardError
      "Inspect the call site."
    end

    def report_annotations(detections)
      detections.each do |detection|
        file, line = parse_frame_location(detection.fix_location || detection.origin_frame)
        query_count = "#{detection.count} queries to `#{detection.table_name || "unknown"}` — #{detection.classification_label}"
        if file
          hint = "Possible fix location (heuristic). #{annotation_hint(detection)}"
          $stdout.puts "::warning file=#{file},line=#{line || 1}::Repeated-query finding: #{query_count}. #{hint}"
        else
          $stdout.puts "::warning ::Repeated-query finding: #{query_count}."
        end
      end
    end
  end
end
