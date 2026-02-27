# frozen_string_literal: true

module AndOne
  # Rack middleware that wraps each request in an N+1 scan.
  # Designed to NOT interfere with error propagation —
  # if the app raises, we cleanly stop scanning without adding
  # to or corrupting the original backtrace.
  class Middleware
    include ScanHelper

    def initialize(app)
      @app = app
    end

    def call(env)
      and_one_wrap { @app.call(env) }
    end
  end
end
