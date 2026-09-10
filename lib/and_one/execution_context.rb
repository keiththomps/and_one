# frozen_string_literal: true

module AndOne
  # Ruby's Thread#[] is intentionally fiber-local. Never share mutable detectors
  # with child fibers, threads, or ActiveRecord's async executor.
  module ExecutionContext
    def self.[](key)
      Thread.current[key]
    end

    def self.[]=(key, value)
      Thread.current[key] = value
    end

    def self.active_detector
      self[:and_one_detector] unless self[:and_one_paused]
    end
  end
end
