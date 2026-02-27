# frozen_string_literal: true

module AndOne
  # Sidekiq server middleware that scans each job for N+1 queries.
  # Covers jobs that use Sidekiq directly (bypassing ActiveJob).
  #
  # If your jobs go through ActiveJob, the ActiveJobHook already covers you —
  # this middleware detects the existing scan and passes through to avoid
  # double-scanning.
  #
  # Manual installation (if not using the Railtie):
  #
  #   Sidekiq.configure_server do |config|
  #     config.server_middleware do |chain|
  #       chain.add AndOne::SidekiqMiddleware
  #     end
  #   end
  #
  class SidekiqMiddleware
    include ScanHelper

    def call(_worker, _msg, _queue)
      and_one_wrap { yield }
    end
  end
end
