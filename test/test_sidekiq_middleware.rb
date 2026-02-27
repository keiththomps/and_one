# frozen_string_literal: true

require "test_helper"

# We test the SidekiqMiddleware without requiring Sidekiq itself —
# it just needs to respond to call(worker, msg, queue) { yield }
class TestSidekiqMiddleware < Minitest::Test
  include AndOneTestHelper

  def setup
    super
    seed_data!
    @middleware = AndOne::SidekiqMiddleware.new
  end

  def teardown
    super
    Comment.delete_all
    Post.delete_all
    Author.delete_all
  end

  def test_detects_n_plus_one_in_job
    captured = nil
    AndOne.notifications_callback = ->(detections, message) {
      captured = detections
    }

    @middleware.call(nil, {}, "default") do
      Post.all.each { |post| post.comments.to_a }
    end

    refute_nil captured
    assert captured.size >= 1
    assert_equal "comments", captured.first.table_name
  end

  def test_no_detection_with_includes
    captured = nil
    AndOne.notifications_callback = ->(detections, message) {
      captured = detections
    }

    @middleware.call(nil, {}, "default") do
      Post.includes(:comments).each { |post| post.comments.to_a }
    end

    assert_nil captured
  end

  def test_does_not_corrupt_error_backtrace
    error = assert_raises(RuntimeError) do
      @middleware.call(nil, {}, "default") do
        raise RuntimeError, "sidekiq job exploded"
      end
    end

    assert_equal "sidekiq job exploded", error.message
    assert error.backtrace.any? { |line| line.include?("test_sidekiq_middleware.rb") }
    refute AndOne.scanning?
  end

  def test_passes_through_when_disabled
    AndOne.enabled = false

    executed = false
    @middleware.call(nil, {}, "default") do
      executed = true
    end

    assert executed
    refute AndOne.scanning?
  end

  def test_does_not_double_scan_when_already_scanning
    # Simulate ActiveJobHook already started a scan
    captured = []
    AndOne.notifications_callback = ->(detections, message) {
      captured << detections
    }

    # Outer scan (simulating ActiveJobHook)
    AndOne.scan do
      # Inner middleware call should pass through, not start its own scan
      @middleware.call(nil, {}, "default") do
        Post.all.each { |post| post.comments.to_a }
      end
    end

    # Should only have been reported once (by the outer scan)
    assert_equal 1, captured.size
  end

  def test_raises_in_raise_mode
    AndOne.raise_on_detect = true

    assert_raises(AndOne::NPlus1Error) do
      @middleware.call(nil, {}, "default") do
        Post.all.each { |post| post.comments.to_a }
      end
    end
  end
end
