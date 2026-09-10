# frozen_string_literal: true

module AndOne
  # Service settings can change between scans. Flush the old writer before
  # replacing it; a failed flush rejects the change rather than losing entries.
  module Configuration
    attr_reader :aggregate_path, :logfile_format, :ignore_file_path, :aggregate_store, :storage_strict
    attr_accessor :dashboard_access_guard

    def capture_mode
      @capture_mode || :redacted
    end

    def capture_mode=(value)
      raise ArgumentError, "capture_mode must be :redacted or :raw" unless %i[redacted raw].include?(value)

      @capture_mode = value
    end

    %i[aggregate_store storage_strict].each do |setting|
      define_method("#{setting}=") do |value|
        @singleton_mutex.synchronize do
          @aggregate = nil unless instance_variable_get("@#{setting}") == value
          instance_variable_set("@#{setting}", value)
        end
      end
    end

    def logfile
      @logfile == :session ? File.join(session.path, "findings.log") : @logfile
    end

    def session
      environment = current_env || "development"
      root = defined?(Rails) && Rails.respond_to?(:root) && Rails.root ? Rails.root.to_s : Dir.pwd
      key = [root, environment, Session.default_id(environment)]
      @session_mutex.synchronize do
        @session = Session.new(root: File.join(root, "tmp/and_one/sessions"), environment: environment, id: key.last) if @session_key != key
        @session_key = key
        @session
      end
    end

    # Call only while session writers are quiescent; running scans may repopulate it.
    # Explicit custom paths are owned by the caller and reset as configured.
    def reset_session!
      logfile_writer&.flush!
      aggregate.reset!
      LogfileWriter.truncate!(logfile)
    end

    def aggregate_path=(value)
      @singleton_mutex.synchronize do
        @aggregate = nil unless @aggregate_path == value
        @aggregate_path = value
      end
    end

    def ignore_file_path=(value)
      @singleton_mutex.synchronize do
        @ignore_list = nil unless @ignore_file_path == value
        @ignore_file_path = value
      end
    end

    %i[logfile logfile_format].each do |setting|
      define_method("#{setting}=") do |value|
        @singleton_mutex.synchronize do
          unless instance_variable_get("@#{setting}") == value
            @logfile_writer&.flush!
            @logfile_writer = nil
          end
          instance_variable_set("@#{setting}", value)
        end
      end
    end

    def apply_rails_defaults
      active = Rails.env.development? || Rails.env.test?
      defaults = { enabled: active, raise_on_detect: Rails.env.test?,
                   logfile: active ? :session : nil,
                   dev_toast: Rails.env.development? }
      defaults.each do |key, value|
        public_send("#{key}=", value) unless instance_variable_defined?("@#{key}")
      end
    end
  end
end
