# frozen_string_literal: true

module AndOne
  class Railtie < Rails::Railtie
    initializer "and_one.defaults", before: :load_config_initializers do
      AndOne.apply_rails_defaults
    end

    initializer "and_one.configure", after: :load_config_initializers do |app|
      if AndOne.enabled?
        at_exit do
          AndOne.logfile_writer&.flush!
        rescue StandardError
          # Swallow errors during shutdown to avoid confusing output
        end

        # Rack middleware for web requests
        app.middleware.insert_before(0, AndOne::Middleware)

        if Rails.env.development?
          # Dev UI dashboard for N+1 overview
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
      end
    end

    # Auto-activate console scanning in development
    console do
      if AndOne.enabled? && Rails.env.development?
        AndOne::Console.activate!

        at_exit { AndOne::Console.deactivate! }
      end
    end
  end
end
