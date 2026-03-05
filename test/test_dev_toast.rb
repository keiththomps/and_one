# frozen_string_literal: true

require "test_helper"

class TestDevToast < Minitest::Test
  include AndOneTestHelper

  def setup
    super
    seed_data!
    AndOne.dev_toast = true
  end

  def teardown
    super
    Comment.delete_all
    Post.delete_all
    Author.delete_all
  end

  # --- DevToast.inject unit tests ---

  def test_inject_returns_original_when_no_detections
    html = "<html><body><p>Hello</p></body></html>"
    assert_equal html, AndOne::DevToast.inject(html, [])
    assert_equal html, AndOne::DevToast.inject(html, nil)
  end

  def test_inject_returns_original_when_no_body_tag
    html = "<div>fragment</div>"
    detections = trigger_detections
    assert_equal html, AndOne::DevToast.inject(html, detections)
  end

  def test_inject_inserts_toast_before_body_close
    html = "<html><body><p>Hello</p></body></html>"
    detections = trigger_detections

    result = AndOne::DevToast.inject(html, detections)

    assert_includes result, "and-one-toast"
    assert_includes result, "AndOne:"
    assert_includes result, "detected"
    assert_includes result, AndOne::DevUI::MOUNT_PATH
    # Toast should appear before </body>
    assert result.index("and-one-toast") < result.index("</body>")
  end

  def test_inject_shows_table_names
    html = "<html><body></body></html>"
    detections = trigger_detections

    result = AndOne::DevToast.inject(html, detections)

    assert_includes result, "comments"
  end

  def test_inject_escapes_html_in_table_names
    detection = AndOne::Detection.new(
      queries: ['SELECT * FROM "<script>evil</script>"'],
      caller_locations: caller_locations,
      count: 5
    )
    # Stub table_name
    detection.define_singleton_method(:table_name) { "<script>evil</script>" }

    html = "<html><body></body></html>"
    result = AndOne::DevToast.inject(html, [detection])

    refute_includes result, "<script>evil</script>"
    assert_includes result, "&lt;script&gt;"
  end

  def test_inject_limits_to_5_summaries
    # Create multiple different detections by querying different associations
    html = "<html><body></body></html>"
    detections = Array.new(7) do |i|
      d = AndOne::Detection.new(
        queries: ["SELECT * FROM table_#{i} WHERE id = 1"] * 3,
        caller_locations: caller_locations,
        count: 3
      )
      d.define_singleton_method(:table_name) { "table_#{i}" }
      d
    end

    result = AndOne::DevToast.inject(html, detections)

    assert_includes result, "table_0"
    assert_includes result, "table_4"
    refute_includes result, ">table_5<"
    assert_includes result, "and 2 more"
  end

  # --- Middleware integration tests ---

  def test_middleware_injects_toast_for_html_responses
    app = lambda { |_env|
      # Trigger an N+1 inside the "request"
      Post.all.each { |post| post.comments.to_a }
      [200, { "content-type" => "text/html; charset=utf-8" }, ["<html><body><p>Posts</p></body></html>"]]
    }

    middleware = AndOne::Middleware.new(app)
    status, headers, body = middleware.call({})

    assert_equal 200, status
    response_body = body.first
    assert_includes response_body, "and-one-toast"
    assert_includes response_body, "comments"
    assert_includes response_body, AndOne::DevUI::MOUNT_PATH
    # Content-Length should be removed since body was modified
    refute headers.key?("content-length")
    refute headers.key?("Content-Length")
  end

  def test_middleware_does_not_inject_for_json_responses
    app = lambda { |_env|
      Post.all.each { |post| post.comments.to_a }
      [200, { "content-type" => "application/json" }, ['{"ok":true}']]
    }

    middleware = AndOne::Middleware.new(app)
    _status, _headers, body = middleware.call({})

    assert_equal '{"ok":true}', body.first
  end

  def test_middleware_does_not_inject_for_non_200_responses
    app = lambda { |_env|
      Post.all.each { |post| post.comments.to_a }
      [302, { "content-type" => "text/html" }, ["<html><body>Redirect</body></html>"]]
    }

    middleware = AndOne::Middleware.new(app)
    _status, _headers, body = middleware.call({})

    refute body.first.include?("and-one-toast")
  end

  def test_middleware_does_not_inject_when_dev_toast_disabled
    AndOne.dev_toast = false

    app = lambda { |_env|
      Post.all.each { |post| post.comments.to_a }
      [200, { "content-type" => "text/html" }, ["<html><body>OK</body></html>"]]
    }

    middleware = AndOne::Middleware.new(app)
    _status, _headers, body = middleware.call({})

    refute body.first.include?("and-one-toast")
  end

  def test_middleware_does_not_inject_when_no_n_plus_ones
    app = lambda { |_env|
      Post.includes(:comments).each { |post| post.comments.to_a }
      [200, { "content-type" => "text/html" }, ["<html><body>OK</body></html>"]]
    }

    middleware = AndOne::Middleware.new(app)
    _status, _headers, body = middleware.call({})

    refute body.first.include?("and-one-toast")
  end

  def test_middleware_still_works_on_errors
    app = ->(_env) { raise "kaboom" }

    middleware = AndOne::Middleware.new(app)

    error = assert_raises(RuntimeError) { middleware.call({}) }
    assert_equal "kaboom", error.message
    refute AndOne.scanning?
  end

  def test_middleware_removes_content_length_header_both_cases
    app = lambda { |_env|
      Post.all.each { |post| post.comments.to_a }
      [200, { "content-type" => "text/html", "Content-Length" => "42" }, ["<html><body>OK</body></html>"]]
    }

    middleware = AndOne::Middleware.new(app)
    _status, headers, _body = middleware.call({})

    refute headers.key?("Content-Length")
  end

  private

  def trigger_detections
    AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end
  end
end
