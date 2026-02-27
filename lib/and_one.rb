# frozen_string_literal: true

require_relative "and_one/version"

module AndOne
  class NPlus1Error < StandardError; end

  # Mutex for protecting lazy singleton initialization (aggregate, ignore_list)
  # and serializing report output so multi-line messages don't interleave
  # across Puma threads.
  @singleton_mutex = Mutex.new
  @report_mutex = Mutex.new

  class << self
    attr_accessor :enabled, :raise_on_detect, :backtrace_cleaner,
                  :allow_stack_paths, :ignore_queries, :ignore_callers,
                  :min_n_queries, :notifications_callback, :aggregate_mode,
                  :ignore_file_path, :json_logging, :env_thresholds

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
      @singleton_mutex.synchronize do
        @aggregate ||= Aggregate.new
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
      thread_state[:and_one_detector] = Detector.new(
        allow_stack_paths: allow_stack_paths || [],
        ignore_queries: ignore_queries || [],
        min_n_queries: effective_min_n_queries
      )
      thread_state[:and_one_paused] = false
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
        ENV["RAILS_ENV"] || ENV["RACK_ENV"]
      end
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
        ignore_list.ignored?(d, d.raw_caller_strings) ||
          caller_ignored?(d.raw_caller_strings)
      end

      return if detections.empty?

      # In aggregate mode, only report NEW unique detections
      if aggregate_mode
        detections = detections.select { |d| aggregate.record(d) }
        return if detections.empty?
      end

      cleaner = backtrace_cleaner || default_backtrace_cleaner

      formatter = Formatter.new(backtrace_cleaner: cleaner)
      message = formatter.format(detections)

      # Serialize all output through a mutex so multi-line messages
      # from concurrent Puma threads don't interleave.
      @report_mutex.synchronize do
        # JSON logging for log aggregation services
        if json_logging
          json_formatter = JsonFormatter.new(backtrace_cleaner: cleaner)
          json_output = json_formatter.format(detections)

          if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
            Rails.logger.warn(json_output)
          else
            $stderr.puts(json_output)
          end
        end

        notifications_callback&.call(detections, message)

        # GitHub Actions annotations
        if ENV["GITHUB_ACTIONS"]
          detections.each do |d|
            file, line = parse_frame_location(d.fix_location || d.origin_frame)
            query_count = "#{d.count} queries to `#{d.table_name || 'unknown'}`"
            if file
              $stdout.puts "::warning file=#{file},line=#{line || 1}::N+1 detected: #{query_count}. Add `.includes(:#{suggest_association_name(d)})` to fix."
            else
              $stdout.puts "::warning ::N+1 detected: #{query_count}."
            end
          end
        end

        if raise_on_detect
          raise NPlus1Error, "\n#{message}"
        else
          unless json_logging
            if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
              Rails.logger.warn("\n#{message}")
            end
            $stderr.puts("\n#{message}") if $stderr.tty?
          end
        end
      end
    end

    def default_backtrace_cleaner
      defined?(Rails) && Rails.respond_to?(:backtrace_cleaner) ? Rails.backtrace_cleaner : nil
    end

    def caller_ignored?(raw_caller_strings)
      patterns = ignore_callers
      return false unless patterns&.any?

      raw_caller_strings.any? do |frame|
        patterns.any? { |pattern| pattern === frame }
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
        [$1, $2.to_i]
      else
        [clean, nil]
      end
    end

    def suggest_association_name(detection)
      suggestion = AssociationResolver.resolve(detection, detection.raw_caller_strings) rescue nil
      suggestion&.association_name || detection.table_name || "association"
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
require_relative "and_one/matchers"
require_relative "and_one/scan_helper"
require_relative "and_one/dev_ui"
require_relative "and_one/console"
require_relative "and_one/middleware"
require_relative "and_one/active_job_hook"
require_relative "and_one/sidekiq_middleware"
require_relative "and_one/railtie" if defined?(Rails::Railtie)
