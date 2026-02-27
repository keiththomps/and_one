# frozen_string_literal: true

require "test_helper"

class TestDevUI < Minitest::Test
  include AndOneTestHelper

  def setup
    super
    seed_data!
  end

  def teardown
    super
    Comment.delete_all
    Post.delete_all
    Author.delete_all
  end

  def test_serves_dashboard_at_mount_path
    app = ->(env) { [200, {}, ["app"]] }
    dev_ui = AndOne::DevUI.new(app)

    status, headers, body = dev_ui.call("PATH_INFO" => "/__and_one")

    assert_equal 200, status
    assert_equal "text/html; charset=utf-8", headers["content-type"]
    html = body.first
    assert_includes html, "AndOne"
    assert_includes html, "N+1 Dashboard"
  end

  def test_passes_through_non_matching_requests
    app = ->(env) { [200, {}, ["app response"]] }
    dev_ui = AndOne::DevUI.new(app)

    _status, _headers, body = dev_ui.call("PATH_INFO" => "/posts")

    assert_equal "app response", body.first
  end

  def test_shows_aggregate_detections
    AndOne.aggregate_mode = true

    AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    app = ->(env) { [200, {}, ["app"]] }
    dev_ui = AndOne::DevUI.new(app)

    _status, _headers, body = dev_ui.call("PATH_INFO" => "/__and_one")

    html = body.first
    assert_includes html, "comments"
    refute_includes html, "No N+1 queries detected yet"
  end

  def test_shows_empty_state_without_aggregate_mode
    AndOne.aggregate_mode = false

    app = ->(env) { [200, {}, ["app"]] }
    dev_ui = AndOne::DevUI.new(app)

    _status, _headers, body = dev_ui.call("PATH_INFO" => "/__and_one")

    html = body.first
    assert_includes html, "No N+1 queries detected yet"
    assert_includes html, "aggregate_mode"
  end
end
