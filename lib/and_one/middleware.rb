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
    def initialize(app)
      @app = app
    end

    def call(env)
      return @app.call(env) if !AndOne.enabled? || AndOne.scanning?

      status = headers = body = nil
      detections = AndOne.scan { status, headers, body = @app.call(env) }

      headers, body = inject_toast(headers, body, detections) if AndOne.dev_toast && detections&.any? && injectable?(env, status, headers, body)

      [status, headers, body]
    end

    private

    def injectable?(env, status, headers, body)
      normalized = headers.transform_keys(&:downcase)
      status == 200 && env["REQUEST_METHOD"] != "HEAD" &&
        normalized["content-type"].to_s.split(";").first.to_s.strip.downcase == "text/html" &&
        !normalized.key?("content-encoding") && !normalized.key?("transfer-encoding") &&
        !normalized.key?("content-range") && !normalized.key?("content-disposition") &&
        !normalized.key?("x-sendfile") && !normalized.key?("x-accel-redirect") &&
        !env["rack.hijack_io"] && !headers.key?("rack.hijack") &&
        body.respond_to?(:to_ary) && !body.respond_to?(:to_path)
    end

    def inject_toast(headers, body, detections)
      # Rack permits eager conversion only through to_ary. That method owns
      # closing the original body (including on failure); do not close it twice.
      chunks = body.to_ary
      full_body = chunks.join
      csp = headers.keys.any? { |key| key.downcase.start_with?("content-security-policy") }
      injected = DevToast.inject(full_body, detections, script_free: csp)
      return [headers, chunks] if injected.equal?(full_body)

      headers = headers.reject do |key, _value|
        %w[content-length etag last-modified content-md5 digest content-digest repr-digest accept-ranges].include?(key.downcase)
      end
      [headers, [injected]]
    end
  end
end
