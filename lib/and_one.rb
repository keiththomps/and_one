# frozen_string_literal: true

require_relative "and_one/version"

module AndOne
  class NPlus1Error < StandardError; end

  class << self
    attr_accessor :enabled, :raise_on_detect, :backtrace_cleaner,
                  :allow_stack_paths, :ignore_queries, :min_n_queries,
                  :notifications_callback

    def configure
      yield self
    end

    def enabled?
      @enabled != false
    end

    # Start scanning for N+1 queries on the current thread.
    # Can be used with a block or as start/finish pair.
    def scan
      return block_given? ? yield : nil unless enabled?
      return block_given? ? yield : nil if scanning?

      start_scan

      if block_given?
        begin
          yield
          detections = detector.finish
          stop_scan
          report(detections) if detections.any?
          detections
        rescue Exception => e
          # On error, clean up without reporting — don't add noise to real errors
          detector&.send(:unsubscribe)
          stop_scan
          raise
        end
      end
    end

    def finish
      return [] unless scanning?

      detections = detector.finish
      stop_scan
      report(detections) if detections.any?
      detections
    end

    def scanning?
      !!thread_state[:and_one_detector]
    end

    def pause
      if block_given?
        was_scanning = scanning?
        thread_state[:and_one_paused] = true
        begin
          yield
        ensure
          thread_state[:and_one_paused] = false if was_scanning
        end
      else
        thread_state[:and_one_paused] = true
      end
    end

    def resume
      thread_state[:and_one_paused] = false
    end

    def paused?
      !!thread_state[:and_one_paused]
    end

    private

    def start_scan
      thread_state[:and_one_detector] = Detector.new(
        allow_stack_paths: allow_stack_paths || [],
        ignore_queries: ignore_queries || [],
        min_n_queries: min_n_queries || 2
      )
      thread_state[:and_one_paused] = false
    end

    def stop_scan
      thread_state[:and_one_detector] = nil
      thread_state[:and_one_paused] = false
    end

    def detector
      thread_state[:and_one_detector]
    end

    def thread_state
      Thread.current
    end

    def report(detections)
      formatter = Formatter.new(
        backtrace_cleaner: backtrace_cleaner || default_backtrace_cleaner
      )

      message = formatter.format(detections)

      notifications_callback&.call(detections, message)

      if raise_on_detect
        raise NPlus1Error, "\n#{message}"
      else
        if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          Rails.logger.warn("\n#{message}")
        end
        $stderr.puts("\n#{message}") if $stderr.tty?
      end
    end

    def default_backtrace_cleaner
      defined?(Rails) && Rails.respond_to?(:backtrace_cleaner) ? Rails.backtrace_cleaner : nil
    end
  end
end

require_relative "and_one/detection"
require_relative "and_one/detector"
require_relative "and_one/fingerprint"
require_relative "and_one/formatter"
require_relative "and_one/association_resolver"
require_relative "and_one/middleware"
require_relative "and_one/railtie" if defined?(Rails::Railtie)
