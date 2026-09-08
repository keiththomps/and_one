# frozen_string_literal: true

module AndOne
  # Internal, non-reporting scan scope for test integrations.
  module TestCapture
    def capture_for_test
      raise ArgumentError, "AndOne matchers cannot run inside an active scan" if scanning?

      unless enabled?
        yield
        return []
      end

      start_scan
      owned_detector = detector
      begin
        yield
        finish_scan(owned_detector, reporting: false)
      ensure
        release_scan(owned_detector)
      end
    end
  end
end
