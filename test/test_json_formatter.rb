# frozen_string_literal: true

require "test_helper"
require "json"

class TestJsonFormatter < Minitest::Test
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

  def test_formats_single_detection_as_json_object
    detections = AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    formatter = AndOne::JsonFormatter.new
    output = formatter.format(detections)
    parsed = JSON.parse(output)

    # Single detection should be a hash, not wrapped in array
    assert_kind_of Hash, parsed
    assert_equal "n_plus_one_detected", parsed["event"]
    assert_equal "warning", parsed["severity"]
    assert_equal "comments", parsed["table"]
    assert parsed["query_count"] >= 2
    assert parsed.key?("fingerprint")
    assert parsed.key?("sample_query")
    assert parsed.key?("timestamp")
    assert parsed.key?("origin")
    assert parsed.key?("backtrace")
  end

  def test_formats_multiple_detections_as_json_array
    detections = AndOne.scan do
      Post.all.each do |post|
        post.comments.to_a
        post.author
      end
    end

    # Only proceed if we got multiple detections
    return if detections.size < 2

    formatter = AndOne::JsonFormatter.new
    output = formatter.format(detections)
    parsed = JSON.parse(output)

    assert_kind_of Array, parsed
    assert_equal detections.size, parsed.size
    parsed.each do |entry|
      assert_equal "n_plus_one_detected", entry["event"]
    end
  end

  def test_includes_suggestion_when_available
    detections = AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    formatter = AndOne::JsonFormatter.new
    output = formatter.format(detections)
    parsed = JSON.parse(output)

    assert parsed.key?("suggestion"), "Expected suggestion in JSON output"
    assert_equal "comments", parsed["suggestion"]["association"]
    assert_equal "Post", parsed["suggestion"]["parent_model"]
    assert_includes parsed["suggestion"]["fix"], "includes(:comments)"
  end

  def test_timestamp_is_iso8601
    detections = AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    formatter = AndOne::JsonFormatter.new
    output = formatter.format(detections)
    parsed = JSON.parse(output)

    # Should parse as a valid time
    timestamp = Time.parse(parsed["timestamp"])
    assert_kind_of Time, timestamp
  end

  def test_backtrace_is_limited_to_10_frames
    detections = AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    formatter = AndOne::JsonFormatter.new
    output = formatter.format(detections)
    parsed = JSON.parse(output)

    assert parsed["backtrace"].size <= 10
  end

  def test_format_hashes_returns_array_of_hashes
    detections = AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    formatter = AndOne::JsonFormatter.new
    hashes = formatter.format_hashes(detections)

    assert_kind_of Array, hashes
    assert_kind_of Hash, hashes.first
    assert_equal "n_plus_one_detected", hashes.first[:event]
    assert_equal "comments", hashes.first[:table]
  end

  def test_json_logging_integration
    AndOne.json_logging = true

    captured_stderr = StringIO.new
    original_stderr = $stderr
    $stderr = captured_stderr

    begin
      AndOne.scan do
        Post.all.each { |post| post.comments.to_a }
      end
    ensure
      $stderr = original_stderr
      AndOne.json_logging = false
    end

    output = captured_stderr.string
    parsed = JSON.parse(output)

    assert_equal "n_plus_one_detected", parsed["event"]
    assert_equal "comments", parsed["table"]
  end
end
