# frozen_string_literal: true

module AndOne
  # Rack middleware that wraps each request in an N+1 scan.
  # Designed to NOT interfere with error propagation —
  # if the app raises, we cleanly stop scanning without adding
  # to or corrupting the original backtrace.
  class Middleware
    def initialize(app)
      @app = app
    end

    def call(env)
      # If AndOne is disabled or already scanning (nested), pass through
      return @app.call(env) unless AndOne.enabled? && !AndOne.scanning?

      begin
        AndOne.scan
        response = @app.call(env)
        AndOne.finish
        response
      rescue Exception => e
        # On ANY error: stop scanning silently, then re-raise the
        # original exception completely untouched.
        # We intentionally do NOT call finish here to avoid double output
        # or masking the real error with N+1 noise.
        quietly_stop_scan
        raise
      end
    end

    private

    def quietly_stop_scan
      # Directly clear thread state without running analysis/notifications.
      # This ensures the original error's backtrace is pristine.
      Thread.current[:and_one_detector]&.send(:unsubscribe)
      Thread.current[:and_one_detector] = nil
      Thread.current[:and_one_paused] = false
    rescue
      # Absolute last resort — never interfere with error propagation
      nil
    end
  end
end
