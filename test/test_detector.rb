# frozen_string_literal: true

require "test_helper"

class TestDetector < Minitest::Test
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

  def test_detects_n_plus_one_on_has_many
    detections = AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    assert_equal 1, detections.size
    detection = detections.first
    assert detection.count >= 2
    assert_equal "comments", detection.table_name
  end

  def test_no_detection_with_includes
    detections = AndOne.scan do
      Post.includes(:comments).each { |post| post.comments.to_a }
    end

    assert_empty detections
  end

  def test_detects_n_plus_one_on_belongs_to
    detections = AndOne.scan do
      Post.all.each { |post| post.author }
    end

    assert_equal 1, detections.size
    assert_equal "authors", detections.first.table_name
  end

  def test_no_detection_with_preload
    detections = AndOne.scan do
      Post.preload(:author).each { |post| post.author }
    end

    assert_empty detections
  end

  def test_no_detection_when_disabled
    AndOne.enabled = false

    # When disabled, scan yields the block but returns the block's own return value
    # (it does not wrap in detection logic)
    result = AndOne.scan do
      "passthrough"
    end

    assert_equal "passthrough", result
  end

  def test_respects_min_n_queries
    AndOne.min_n_queries = 100

    detections = AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    assert_empty detections
  end

  def test_pause_and_resume
    detections = AndOne.scan do
      # This should be detected
      Post.limit(3).each { |post| post.comments.to_a }

      AndOne.pause do
        # This should NOT be detected
        Post.limit(3).each { |post| post.author }
      end
    end

    # Should only detect the comments N+1, not the paused author one
    tables = detections.map(&:table_name)
    assert_includes tables, "comments"
    refute_includes tables, "authors"
  end

  def test_ignore_queries
    AndOne.ignore_queries = [/comments/]

    detections = AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    assert_empty detections
  end

  def test_block_form_returns_detections
    detections = AndOne.scan do
      42 # block value is discarded; scan returns detections array
    end

    assert_equal [], detections
  end

  def test_nested_scan_passes_through
    outer = AndOne.scan do
      inner = AndOne.scan do
        "inner_result"
      end
      assert_equal "inner_result", inner
      Post.all.each { |post| post.comments.to_a }
    end

    # Outer should still detect
    assert outer.is_a?(Array)
    assert outer.size >= 1
  end
end
