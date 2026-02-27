# frozen_string_literal: true

require "test_helper"

class TestMinitestHelper < Minitest::Test
  include AndOneTestHelper
  include AndOne::MinitestHelper

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

  def test_assert_no_n_plus_one_passes_with_includes
    assert_no_n_plus_one do
      Post.includes(:comments).each { |post| post.comments.to_a }
    end
  end

  def test_assert_no_n_plus_one_fails_without_includes
    error = assert_raises(Minitest::Assertion) do
      assert_no_n_plus_one do
        Post.all.each { |post| post.comments.to_a }
      end
    end

    assert_includes error.message, "N+1"
    assert_includes error.message, "comments"
  end

  def test_assert_no_n_plus_one_custom_message
    error = assert_raises(Minitest::Assertion) do
      assert_no_n_plus_one("my custom message") do
        Post.all.each { |post| post.comments.to_a }
      end
    end

    assert_equal "my custom message", error.message
  end

  def test_assert_n_plus_one_passes_when_detected
    detections = assert_n_plus_one do
      Post.all.each { |post| post.comments.to_a }
    end

    assert detections.size >= 1
    assert_equal "comments", detections.first.table_name
  end

  def test_assert_n_plus_one_fails_when_clean
    error = assert_raises(Minitest::Assertion) do
      assert_n_plus_one do
        Post.includes(:comments).each { |post| post.comments.to_a }
      end
    end

    assert_includes error.message, "Expected N+1 queries, but none were detected"
  end

  def test_matchers_dont_interfere_with_raise_on_detect
    # Even if raise_on_detect is true, matchers should work normally
    # (they temporarily disable it internally)
    AndOne.raise_on_detect = true

    assert_no_n_plus_one do
      Post.includes(:comments).each { |post| post.comments.to_a }
    end

    # And assert_n_plus_one should return detections, not raise
    detections = assert_n_plus_one do
      Post.all.each { |post| post.comments.to_a }
    end

    assert detections.size >= 1
  end

  def test_matchers_restore_callback
    original_callback = ->(_d, _m) { "original" }
    AndOne.notifications_callback = original_callback

    assert_no_n_plus_one do
      Post.includes(:comments).each { |post| post.comments.to_a }
    end

    assert_equal original_callback, AndOne.notifications_callback
  end

  def test_failure_message_includes_query_count
    error = assert_raises(Minitest::Assertion) do
      assert_no_n_plus_one do
        Post.all.each { |post| post.comments.to_a }
      end
    end

    # Should include query count like "X queries to `comments` (expected 1)"
    assert_match(/\d+ queries to `comments` \(expected 1\)/, error.message)
  end
end
