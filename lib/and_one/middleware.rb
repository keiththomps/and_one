# frozen_string_literal: true

module AndOne
  # Rack middleware that wraps each request in an N+1 scan.
  # Designed to NOT interfere with error propagation —
  # if the app raises, we cleanly stop scanning without adding
  # to or corrupting the original backtrace.
  #
  # When `AndOne.dev_toast` is enabled (default in development),
  # detected N+1s are injected as a toast notification into HTML responses
  # with a link to the DevUI dashboard.
  class Middleware
    include ScanHelper

    def initialize(app)
      @app = app
    end

    def call(env)
      return @app.call(env) if !AndOne.enabled? || AndOne.scanning?

      begin
        AndOne.scan
        status, headers, body = @app.call(env)
        detections = AndOne.finish

        if AndOne.dev_toast && detections&.any? && html_response?(headers) && status == 200
          body = inject_toast(body, detections)
          # Recalculate Content-Length since we modified the body
          headers.delete("content-length")
          headers.delete("Content-Length")
        end

        [status, headers, body]
      rescue Exception # rubocop:disable Lint/RescueException
        and_one_quietly_stop
        raise
      end
    end

    private

    def html_response?(headers)
      content_type = headers["content-type"] || headers["Content-Type"]
      content_type&.include?("text/html")
    end

    def inject_toast(body, detections)
      full_body = +""
      body.each { |chunk| full_body << chunk }
      body.close if body.respond_to?(:close)

      injected = DevToast.inject(full_body, detections)
      [injected]
    end
  end
end
