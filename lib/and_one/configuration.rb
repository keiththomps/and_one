# frozen_string_literal: true

module AndOne
  # Service settings can change between scans. Flush the old writer before
  # replacing it; a failed flush rejects the change rather than losing entries.
  module Configuration
    attr_reader :aggregate_path, :logfile, :logfile_format, :ignore_file_path

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
                   logfile: active ? Rails.root.join("log/and_one.log").to_s : nil,
                   dev_toast: Rails.env.development? }
      defaults.each do |key, value|
        public_send("#{key}=", value) unless instance_variable_defined?("@#{key}")
      end
    end
  end
end
