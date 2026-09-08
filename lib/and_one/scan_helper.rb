# frozen_string_literal: true

module AndOne
  # Preserve the application's return value while using scan's owned lifecycle.
  module ScanHelper
    private

    def and_one_wrap
      result = nil
      AndOne.scan { result = yield }
      result
    end
  end
end
