# frozen_string_literal: true

require "test_helper"
require "rack/mock"
require "rack/lint"
require "rack/deflater"

class TestToastContract < Minitest::Test
  include AndOneTestHelper

  # A Rack-compliant buffered body owns cleanup in to_ary, even on errors.
  class BufferedBody
    attr_reader :closes

    def initialize(fail: false)
      @fail = fail
      @closes = 0
    end

    def each
      raise "enumeration failed" if @fail

      yield "<html><body>OK</body></html>"
    end

    def to_ary
      chunks = []
      each { |chunk| chunks << chunk }
      chunks
    ensure
      close
    end

    def close
      @closes += 1
    end
  end

  def setup
    super
    AndOne.dev_toast = true
  end

  def app(body, headers = { "content-type" => "text/html" }, status = 200)
    lambda do |_env|
      3.times { Post.where(id: 1).to_a }
      [status, headers, body]
    end
  end

  def request(application, method = "GET")
    application.call(Rack::MockRequest.env_for("/", method: method))
  end

  def test_buffered_body_closes_once_and_passes_rack_lint
    original = BufferedBody.new
    response = Rack::MockRequest.new(Rack::Lint.new(AndOne::Middleware.new(app(original)))).get("/")
    assert_includes response.body, "and-one-toast"
    assert_equal 1, original.closes
  end

  def test_conversion_error_closes_once_and_leaves_scan_stopped
    original = BufferedBody.new(fail: true)
    error = assert_raises(RuntimeError) { request(AndOne::Middleware.new(app(original))) }
    assert_equal "enumeration failed", error.message
    assert_equal 1, original.closes
    refute AndOne.scanning?
  end

  def test_lazy_and_streaming_bodies_are_not_consumed
    [Object.new, Object.new].each_with_index do |body, index|
      body.define_singleton_method(index.zero? ? :each : :call) { |*| raise "consumed" }
      body.define_singleton_method(:close) { raise "closed" }
      assert_same body, request(AndOne::Middleware.new(app(body))).last
    end
  end

  def test_lazy_sql_is_outside_scan
    body = Object.new
    body.define_singleton_method(:each) do |&block|
      3.times { Post.where(id: 1).to_a }
      block.call("<body>OK</body>")
    end
    middleware = AndOne::Middleware.new(->(_) { [200, { "content-type" => "text/html" }, body] })
    result = request(middleware).last
    result.each { |chunk| refute_includes chunk, "and-one-toast" }
    assert_empty AndOne.aggregate.detections
  end

  def test_ineligible_responses_preserve_body_and_headers
    variants = [
      [200, "HEAD", {}], [302, "GET", {}], [500, "GET", {}], [204, "GET", {}],
      [200, "GET", { "content-type" => "application/json" }],
      [200, "GET", { "content-type" => "text/htmlish" }],
      [200, "GET", { "Content-Encoding" => "gzip" }],
      [200, "GET", { "transfer-encoding" => "chunked" }],
      [200, "GET", { "content-range" => "bytes 0-10/20" }],
      [200, "GET", { "content-disposition" => "attachment" }]
    ]
    variants.each do |status, method, extra|
      headers = { "content-type" => "text/html", "etag" => "old" }.merge(extra)
      body = BufferedBody.new
      response = request(AndOne::Middleware.new(app(body, headers, status)), method)
      assert_same headers, response[1]
      assert_same body, response[2]
      assert_equal 0, body.closes
    end
  end

  def test_compression_on_either_side_of_middleware
    html = ["<body>OK</body>"]
    inner = AndOne::Middleware.new(Rack::Deflater.new(app(html)))
    outer = Rack::Deflater.new(AndOne::Middleware.new(app(html)))
    [inner, outer].each_with_index do |stack, index|
      response = Rack::MockRequest.new(stack).get("/", "HTTP_ACCEPT_ENCODING" => "gzip")
      assert_equal "gzip", response["content-encoding"]
      decoded = Zlib::GzipReader.new(StringIO.new(response.body)).read
      assert_equal index == 1, decoded.include?("and-one-toast")
    end
  end

  def test_metadata_removed_only_when_transformed_and_frozen_headers_supported
    headers = { "content-type" => "text/html", "Content-Length" => "20", "ETag" => "old",
                "Last-Modified" => "yesterday", "Digest" => "old", "content-md5" => "old",
                "content-digest" => "old", "repr-digest" => "old", "accept-ranges" => "bytes" }.freeze
    changed = request(AndOne::Middleware.new(app(["<BODY>OK</BODY>"], headers)))
    assert_equal({ "content-type" => "text/html" }, changed[1])
    unchanged = request(AndOne::Middleware.new(app(["fragment"], headers)))
    assert_same headers, unchanged[1]
    assert_equal ["fragment"], unchanged[2]
  end

  def test_strict_csp_uses_native_details_without_active_assets
    policy = "default-src 'none'; script-src 'none'; style-src 'none'"
    headers = { "content-type" => "text/html", "Content-Security-Policy" => policy }
    response = request(AndOne::Middleware.new(app(["<body>OK</body>"], headers)))
    assert_equal policy, response[1]["Content-Security-Policy"]
    assert_fallback response[2].join
    meta = %(<head><meta http-equiv="Content-Security-Policy" content="#{policy}"></head><body>OK</body>)
    assert_fallback request(AndOne::Middleware.new(app([meta])))[2].join
  end

  def test_ignored_findings_do_not_produce_a_toast
    AndOne.ignore_queries = [/posts/]
    body = ["<body>OK</body>"]
    assert_same body, request(AndOne::Middleware.new(app(body))).last
  end

  private

  def assert_fallback(html)
    assert_includes html, "<details>"
    assert_includes html, "posts"
    assert_includes html, AndOne::DevUI::MOUNT_PATH
    refute_match(/<script|<style|onclick=|style=/i, html)
  end
end
