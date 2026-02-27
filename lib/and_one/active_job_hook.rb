# frozen_string_literal: true

module AndOne
  # Hooks into ActiveJob's around_perform callback to scan every job for N+1 queries.
  # Works with any ActiveJob backend: Sidekiq, GoodJob, SolidQueue, Delayed Job, etc.
  #
  # Automatically installed by the Railtie. Can also be installed manually:
  #
  #   ActiveJob::Base.include(AndOne::ActiveJobHook)
  #
  module ActiveJobHook
    extend ActiveSupport::Concern
    include ScanHelper

    included do
      around_perform :and_one_scan
    end

    private

    def and_one_scan(&)
      and_one_wrap(&)
    end
  end
end
