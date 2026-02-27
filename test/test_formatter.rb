# frozen_string_literal: true

require "test_helper"

class TestFormatter < Minitest::Test
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

  def test_formats_detection_output
    detections = AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    formatter = AndOne::Formatter.new
    output = formatter.format(detections)

    assert_includes output, "And One!"
    assert_includes output, "N+1"
    assert_includes output, "comments"
    assert_includes output, "repeated query"
  end

  def test_notifications_callback
    captured = nil
    AndOne.notifications_callback = ->(detections, message) {
      captured = { detections: detections, message: message }
    }

    AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    refute_nil captured
    assert captured[:detections].size >= 1
    assert_includes captured[:message], "And One!"
  end

  def test_raise_on_detect
    AndOne.raise_on_detect = true

    assert_raises(AndOne::NPlus1Error) do
      AndOne.scan do
        Post.all.each { |post| post.comments.to_a }
      end
    end
  end

  def test_association_suggestion
    detections = AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    formatter = AndOne::Formatter.new
    output = formatter.format(detections)

    # Should suggest the fix
    assert_includes output, "includes(:comments)"
  end
end
