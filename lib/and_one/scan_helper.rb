# frozen_string_literal: true

module AndOne
  # Shared scan lifecycle for middleware/hooks.
  # Wraps a block in AndOne.scan with clean error handling
  # that never interferes with the original exception.
  module ScanHelper
    private

    def and_one_wrap
      return yield if !AndOne.enabled? || AndOne.scanning?

      begin
        AndOne.scan
        result = yield
        AndOne.finish
        result
      rescue Exception # rubocop:disable Lint/RescueException
        and_one_quietly_stop
        raise
      end
    end

    def and_one_quietly_stop
      Thread.current[:and_one_detector]&.send(:unsubscribe)
      Thread.current[:and_one_detector] = nil
      Thread.current[:and_one_paused] = false
    rescue StandardError
      nil
    end
  end
end
