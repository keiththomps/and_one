# frozen_string_literal: true

require "test_helper"

class TestAndOne < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::AndOne::VERSION
  end
end

class TestGithubActionsAnnotations < Minitest::Test
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
    ENV.delete("GITHUB_ACTIONS")
  end

  def test_outputs_github_annotations_when_env_set
    ENV["GITHUB_ACTIONS"] = "true"

    output = capture_stdout do
      AndOne.scan do
        Post.all.each { |post| post.comments.to_a }
      end
    end

    assert_match(/^::warning /, output)
    assert_includes output, "N+1 detected"
    assert_includes output, "comments"
  end

  def test_no_github_annotations_without_env
    ENV.delete("GITHUB_ACTIONS")

    output = capture_stdout do
      AndOne.scan do
        Post.all.each { |post| post.comments.to_a }
      end
    end

    refute_match(/^::warning /, output)
  end

  private

  def capture_stdout
    old_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old_stdout
  end
end

class TestIgnoreCallers < Minitest::Test
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

  def test_ignore_callers_suppresses_matching_detections
    AndOne.ignore_callers = [/test_and_one/]

    captured = nil
    AndOne.notifications_callback = ->(dets, _msg) { captured = dets }

    AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    assert_nil captured, "Expected detection to be ignored by caller pattern"
  end

  def test_ignore_callers_does_not_suppress_non_matching
    AndOne.ignore_callers = [/nonexistent_file_pattern/]

    captured = nil
    AndOne.notifications_callback = ->(dets, _msg) { captured = dets }

    AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    refute_nil captured, "Expected detection NOT to be ignored"
  end

  def test_ignore_callers_with_non_matching_path_pattern
    AndOne.ignore_callers = [%r{app/views/admin}]

    captured = nil
    AndOne.notifications_callback = ->(dets, _msg) { captured = dets }

    # This call stack doesn't include admin views, so should still detect
    AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    refute_nil captured
  end
end
