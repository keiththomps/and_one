# frozen_string_literal: true

require "test_helper"
require "tempfile"

class TestIgnoreFile < Minitest::Test
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

  def test_ignores_by_fingerprint
    # First, detect to get a fingerprint
    detections = AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    fp = detections.first.fingerprint

    # Now create ignore file with that fingerprint
    with_ignore_file("fingerprint:#{fp}") do |path|
      AndOne.ignore_file_path = path
      AndOne.reload_ignore_file!

      captured = nil
      AndOne.notifications_callback = ->(dets, _msg) { captured = dets }

      AndOne.scan do
        Post.all.each { |post| post.comments.to_a }
      end

      assert_nil captured, "Expected detection to be ignored by fingerprint"
    end
  end

  def test_ignores_by_query_pattern
    with_ignore_file("query:comments") do |path|
      AndOne.ignore_file_path = path
      AndOne.reload_ignore_file!

      captured = nil
      AndOne.notifications_callback = ->(dets, _msg) { captured = dets }

      AndOne.scan do
        Post.all.each { |post| post.comments.to_a }
      end

      assert_nil captured, "Expected detection to be ignored by query pattern"
    end
  end

  def test_ignores_by_gem_pattern
    # The call stack passes through activerecord gem
    with_ignore_file("gem:activerecord") do |path|
      AndOne.ignore_file_path = path
      AndOne.reload_ignore_file!

      captured = nil
      AndOne.notifications_callback = ->(dets, _msg) { captured = dets }

      AndOne.scan do
        Post.all.each { |post| post.comments.to_a }
      end

      assert_nil captured, "Expected detection to be ignored by gem pattern"
    end
  end

  def test_ignores_by_path_glob
    # The call stack includes this test file
    with_ignore_file("path:test/test_ignore_file*") do |path|
      AndOne.ignore_file_path = path
      AndOne.reload_ignore_file!

      captured = nil
      AndOne.notifications_callback = ->(dets, _msg) { captured = dets }

      AndOne.scan do
        Post.all.each { |post| post.comments.to_a }
      end

      assert_nil captured, "Expected detection to be ignored by path glob"
    end
  end

  def test_does_not_ignore_when_no_match
    with_ignore_file("gem:nonexistent_gem\nquery:nonexistent_table") do |path|
      AndOne.ignore_file_path = path
      AndOne.reload_ignore_file!

      captured = nil
      AndOne.notifications_callback = ->(dets, _msg) { captured = dets }

      AndOne.scan do
        Post.all.each { |post| post.comments.to_a }
      end

      refute_nil captured, "Expected detection NOT to be ignored"
    end
  end

  def test_skips_comments_and_blank_lines
    content = <<~IGNORE
      # This is a comment

      # Another comment
      query:comments
    IGNORE

    with_ignore_file(content) do |path|
      AndOne.ignore_file_path = path
      AndOne.reload_ignore_file!

      captured = nil
      AndOne.notifications_callback = ->(dets, _msg) { captured = dets }

      AndOne.scan do
        Post.all.each { |post| post.comments.to_a }
      end

      assert_nil captured
    end
  end

  def test_handles_missing_ignore_file
    AndOne.ignore_file_path = "/tmp/nonexistent_and_one_ignore"
    AndOne.reload_ignore_file!

    captured = nil
    AndOne.notifications_callback = ->(dets, _msg) { captured = dets }

    AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    refute_nil captured, "Should still detect when ignore file doesn't exist"
  end

  private

  def with_ignore_file(content)
    file = Tempfile.new(".and_one_ignore")
    file.write(content)
    file.close
    yield file.path
  ensure
    file.unlink
  end
end
