# frozen_string_literal: true

module AndOne
  class Railtie < Rails::Railtie
    initializer "and_one.configure" do |app|
      # Only activate in development and test by default
      if Rails.env.development? || Rails.env.test?
        AndOne.enabled = true

        # In test, raise by default so N+1s fail the test suite
        AndOne.raise_on_detect = true if Rails.env.test?

        app.middleware.insert_before(0, AndOne::Middleware)
      else
        AndOne.enabled = false
      end
    end
  end
end
