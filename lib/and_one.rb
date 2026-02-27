# frozen_string_literal: true

require_relative "and_one/version"

module AndOne
  class NPlus1Error < StandardError; end

  class << self
    attr_accessor :enabled, :raise_on_detect, :backtrace_cleaner,
                  :allow_stack_paths, :ignore_queries, :min_n_queries,
                  :notifications_callback, :aggregate_mode, :ignore_file_path

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

    def aggregate
      @aggregate ||= Aggregate.new
    end

    def ignore_list
      @ignore_list ||= IgnoreFile.new(resolve_ignore_file_path)
    end

    # Reset cached ignore file (useful after config change)
    def reload_ignore_file!
      @ignore_list = nil
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
      # Filter out ignored detections
      detections = detections.reject do |d|
        ignore_list.ignored?(d, d.raw_caller_strings)
      end

      return if detections.empty?

      # In aggregate mode, only report NEW unique detections
      if aggregate_mode
        detections = detections.select { |d| aggregate.record(d) }
        return if detections.empty?
      end

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

    def resolve_ignore_file_path
      return ignore_file_path if ignore_file_path

      if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
        Rails.root.join(".and_one_ignore").to_s
      else
        File.join(Dir.pwd, ".and_one_ignore")
      end
    end
  end
end

require_relative "and_one/detection"
require_relative "and_one/detector"
require_relative "and_one/fingerprint"
require_relative "and_one/formatter"
require_relative "and_one/association_resolver"
require_relative "and_one/ignore_file"
require_relative "and_one/aggregate"
require_relative "and_one/matchers"
require_relative "and_one/scan_helper"
require_relative "and_one/middleware"
require_relative "and_one/active_job_hook"
require_relative "and_one/sidekiq_middleware"
require_relative "and_one/railtie" if defined?(Rails::Railtie)
