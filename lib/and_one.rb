# frozen_string_literal: true

require "logger"
require "active_record"
require "rails/railtie"

require_relative "and_one/version"
require_relative "and_one/execution_context"
require_relative "and_one/sql_subscriber"
require_relative "and_one/test_capture"
require_relative "and_one/query_capture"
require_relative "and_one/reporting"
require_relative "and_one/configuration"

module AndOne
  class NPlus1Error < StandardError; end

  extend Configuration
  extend Reporting
  extend TestCapture

  # Mutex for protecting lazy singleton initialization (aggregate, ignore_list)
  # and serializing report output so multi-line messages don't interleave
  # across Puma threads.
  @singleton_mutex = Mutex.new
  @report_mutex = Mutex.new

  class << self
    attr_accessor :enabled, :raise_on_detect, :backtrace_cleaner,
                  :allow_stack_paths, :ignore_queries, :ignore_callers,
                  :min_n_queries, :notifications_callback,
                  :json_logging, :env_thresholds,
                  :dev_toast, :dev_toast_position

    def configure
      yield self
    end

    def enabled?
      @enabled != false
    end

    # Start scanning for N+1 queries in the current fiber.
    # Can be used with a block or as start/finish pair.
    def scan
      return block_given? ? yield : nil unless enabled?
      return block_given? ? yield : nil if scanning?

      start_scan
      return unless block_given?

      owned_detector = detector
      begin
        yield
        finish_scan(owned_detector)
      ensure
        release_scan(owned_detector)
      end
    end

    def finish
      finish_scan(detector)
    end

    def scanning?
      !!execution_context[:and_one_detector]
    end

    def pause
      if block_given?
        was_paused = execution_context[:and_one_paused]
        execution_context[:and_one_paused] = true
        begin
          yield
        ensure
          execution_context[:and_one_paused] = was_paused
        end
      else
        execution_context[:and_one_paused] = true
      end
    end

    def resume
      execution_context[:and_one_paused] = false
    end

    def paused?
      !!execution_context[:and_one_paused]
    end

    def aggregate
      @singleton_mutex.synchronize do
        @aggregate ||= Aggregate.new(path: aggregate_path)
      end
    end

    def logfile_writer
      return nil unless logfile

      @singleton_mutex.synchronize do
        @logfile_writer ||= LogfileWriter.new(
          path: logfile,
          format: logfile_format || :text
        )
      end
    end

    def ignore_list
      @singleton_mutex.synchronize do
        @ignore_list ||= IgnoreFile.new(resolve_ignore_file_path)
      end
    end

    # Reset cached ignore file (useful after config change)
    def reload_ignore_file!
      @singleton_mutex.synchronize do
        @ignore_list = nil
      end
    end

    private

    def start_scan
      execution_context[:and_one_detector] = Detector.new(
        allow_stack_paths: allow_stack_paths || [],
        ignore_queries: ignore_queries || [],
        min_n_queries: effective_min_n_queries,
        ignore_list: ignore_list
      )
      execution_context[:and_one_paused] = false
    end

    # Resolve the effective min_n_queries, checking per-environment thresholds
    # first, then falling back to the global setting.
    #
    # Configure per-environment thresholds:
    #   AndOne.env_thresholds = { "development" => 3, "test" => 2 }
    #
    def effective_min_n_queries
      if env_thresholds.is_a?(Hash) && current_env
        threshold = env_thresholds[current_env] || env_thresholds[current_env.to_sym]
        return threshold if threshold
      end

      min_n_queries || 2
    end

    def current_env
      if defined?(Rails) && Rails.respond_to?(:env)
        Rails.env.to_s
      else
        ENV["RAILS_ENV"] || ENV.fetch("RACK_ENV", nil)
      end
    end

    def finish_scan(owned_detector, reporting: true)
      return [] unless owned_detector && detector.equal?(owned_detector)

      begin
        detections = owned_detector.finish
      ensure
        release_scan(owned_detector)
      end
      detections = apply_ignore_filter(detections)
      report(detections) if reporting && detections.any?
      detections
    end

    def release_scan(owned_detector)
      return unless detector.equal?(owned_detector)

      execution_context[:and_one_detector] = nil
      execution_context[:and_one_paused] = false
    end

    def detector
      execution_context[:and_one_detector]
    end

    def execution_context
      ExecutionContext
    end

    def apply_ignore_filter(detections)
      detections.reject do |d|
        ignore_list.ignored?(d, d.raw_caller_strings) ||
          caller_ignored?(d.raw_caller_strings)
      end
    end

    def default_backtrace_cleaner
      defined?(Rails) && Rails.respond_to?(:backtrace_cleaner) ? Rails.backtrace_cleaner : nil
    end

    def caller_ignored?(raw_caller_strings)
      patterns = ignore_callers
      return false unless patterns&.any?

      raw_caller_strings.any? do |frame|
        patterns.any? { |pattern| pattern.match?(frame) }
      end
    end

    def parse_frame_location(frame)
      return [nil, nil] unless frame

      # Extract file:line from a backtrace frame like "app/controllers/posts_controller.rb:15:in `index'"
      clean = frame
              .sub(%r{.*/app/}, "app/")
              .sub(%r{.*/lib/}, "lib/")
              .sub(%r{.*/test/}, "test/")
              .sub(%r{.*/spec/}, "spec/")

      if clean =~ /\A(.+?):(\d+)/
        [::Regexp.last_match(1), ::Regexp.last_match(2).to_i]
      else
        [clean, nil]
      end
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
require_relative "and_one/json_formatter"
require_relative "and_one/association_resolver"
require_relative "and_one/ignore_file"
require_relative "and_one/aggregate"
require_relative "and_one/logfile_writer"
require_relative "and_one/matchers"
require_relative "and_one/query_matchers"
require_relative "and_one/scan_helper"
require_relative "and_one/dev_ui"
require_relative "and_one/dev_toast"
require_relative "and_one/console"
require_relative "and_one/middleware"
require_relative "and_one/active_job_hook"
require_relative "and_one/sidekiq_middleware"
require_relative "and_one/railtie" if defined?(Rails::Railtie)

AndOne::SqlSubscriber.install!
