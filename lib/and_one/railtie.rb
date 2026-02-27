# frozen_string_literal: true

module AndOne
  class Railtie < Rails::Railtie
    initializer "and_one.configure" do |app|
      # Only activate in development and test by default
      if Rails.env.development? || Rails.env.test?
        AndOne.enabled = true

        # In test, raise by default so N+1s fail the test suite
        AndOne.raise_on_detect = true if Rails.env.test?

        # Rack middleware for web requests
        app.middleware.insert_before(0, AndOne::Middleware)

        # Dev UI dashboard for N+1 overview (requires aggregate_mode)
        if Rails.env.development?
          app.middleware.use(AndOne::DevUI)
        end

        # ActiveJob hook — covers all job backends (Sidekiq, GoodJob, SolidQueue, etc.)
        ActiveSupport.on_load(:active_job) do
          include AndOne::ActiveJobHook
        end

        # Sidekiq server middleware — covers jobs that bypass ActiveJob
        if defined?(::Sidekiq)
          ::Sidekiq.configure_server do |config|
            config.server_middleware do |chain|
              chain.add AndOne::SidekiqMiddleware
            end
          end
        end
      else
        AndOne.enabled = false
      end
    end
  end
end
