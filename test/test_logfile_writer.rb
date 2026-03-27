# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "json"

class TestLogfileWriter < Minitest::Test
  include AndOneTestHelper

  def setup
    super
    seed_data!
    @tmpdir = Dir.mktmpdir("and_one_test")
    @logfile = File.join(@tmpdir, "and_one.log")
  end

  def teardown
    super
    Comment.delete_all
    Post.delete_all
    Author.delete_all
    FileUtils.rm_rf(@tmpdir)
  end

  def test_flush_with_no_entries_is_noop
    writer = AndOne::LogfileWriter.new(path: @logfile, format: :text)
    writer.flush!

    refute File.exist?(@logfile)
  end

  def test_buffers_and_deduplicates_by_fingerprint
    writer = AndOne::LogfileWriter.new(path: @logfile, format: :json)
    detections = capture_detections do
      Post.all.each { |post| post.comments.to_a }
    end

    # Record the same detections twice
    writer.record(detections)
    writer.record(detections)
    writer.flush!

    content = File.read(@logfile)
    lines = content.strip.split("\n")
    # Should only have one line per unique fingerprint despite recording twice
    fingerprints = lines.map { |l| JSON.parse(l)["fingerprint"] }
    assert_equal fingerprints.uniq, fingerprints
  end

  def test_text_format_has_no_ansi_codes
    writer = AndOne::LogfileWriter.new(path: @logfile, format: :text)
    detections = capture_detections do
      Post.all.each { |post| post.comments.to_a }
    end

    writer.record(detections)
    writer.flush!

    content = File.read(@logfile)
    refute_match(/\e\[\d+m/, content, "Logfile should not contain ANSI color codes")
    assert_includes content, "N+1"
  end

  def test_json_format_produces_valid_jsonl
    writer = AndOne::LogfileWriter.new(path: @logfile, format: :json)
    detections = capture_detections do
      Post.all.each { |post| post.comments.to_a }
    end

    writer.record(detections)
    writer.flush!

    content = File.read(@logfile)
    lines = content.strip.split("\n")
    assert lines.size >= 1

    lines.each do |line|
      parsed = JSON.parse(line)
      assert_equal "n_plus_one_detected", parsed["event"]
      assert parsed.key?("fingerprint")
      assert parsed.key?("table")
    end
  end

  def test_truncate_clears_stale_file
    File.write(@logfile, "stale data\n")

    AndOne::LogfileWriter.truncate!(@logfile)

    assert_equal 0, File.size(@logfile)
  end

  def test_truncate_is_noop_when_file_missing
    AndOne::LogfileWriter.truncate!(@logfile)

    refute File.exist?(@logfile)
  end

  def test_truncate_is_noop_when_path_nil
    AndOne::LogfileWriter.truncate!(nil)
  end

  def test_appends_to_existing_file
    # Pre-existing content should be preserved (truncation is handled at boot
    # in the railtie, not by the writer)
    File.write(@logfile, "existing data\n")

    writer = AndOne::LogfileWriter.new(path: @logfile, format: :text)
    detections = capture_detections do
      Post.all.each { |post| post.comments.to_a }
    end

    writer.record(detections)
    writer.flush!

    content = File.read(@logfile)
    assert_includes content, "existing data"
    assert_includes content, "N+1"
  end

  def test_parallel_workers_both_append
    # Simulate two parallel workers flushing to the same file
    writer = AndOne::LogfileWriter.new(path: @logfile, format: :text)
    writer2 = AndOne::LogfileWriter.new(path: @logfile, format: :text)

    detections_comments = capture_detections do
      Post.all.each { |post| post.comments.to_a }
    end

    detections_authors = capture_detections do
      Post.all.each(&:author)
    end

    writer.record(detections_comments)
    writer.flush!

    first_content = File.read(@logfile)

    writer2.record(detections_authors)
    writer2.flush!

    final_content = File.read(@logfile)
    # Both workers' findings should be present
    assert final_content.length > first_content.length
    assert_includes final_content, "comments"
    assert_includes final_content, "authors"
  end

  def test_file_locking_does_not_deadlock
    writer = AndOne::LogfileWriter.new(path: @logfile, format: :text)
    detections = capture_detections do
      Post.all.each { |post| post.comments.to_a }
    end

    writer.record(detections)

    # Flush twice in sequence to verify no deadlock
    writer.flush!
    # Second flush has no new entries (already flushed), but should not deadlock
    writer2 = AndOne::LogfileWriter.new(path: @logfile, format: :text)
    writer2.record(detections)
    writer2.flush!

    assert File.exist?(@logfile)
  end

  def test_creates_intermediate_directories
    nested_path = File.join(@tmpdir, "sub", "dir", "and_one.log")
    writer = AndOne::LogfileWriter.new(path: nested_path, format: :text)
    detections = capture_detections do
      Post.all.each { |post| post.comments.to_a }
    end

    writer.record(detections)
    writer.flush!

    assert File.exist?(nested_path)
  end

  def test_integration_with_and_one_scan
    AndOne.logfile = @logfile
    AndOne.logfile_format = :text

    AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    AndOne.logfile_writer.flush!

    content = File.read(@logfile)
    assert_includes content, "N+1"
    assert_includes content, "comments"
  end

  def test_integration_json_format
    AndOne.logfile = @logfile
    AndOne.logfile_format = :json

    AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    AndOne.logfile_writer.flush!

    content = File.read(@logfile)
    lines = content.strip.split("\n")
    lines.each do |line|
      parsed = JSON.parse(line)
      assert_equal "n_plus_one_detected", parsed["event"]
    end
  end

  private

  def capture_detections(&)
    detections = []
    original_callback = AndOne.notifications_callback
    AndOne.notifications_callback = ->(dets, _msg) { detections.concat(dets) }

    AndOne.scan(&)

    AndOne.notifications_callback = original_callback
    # Reset aggregate so subsequent scans report again
    AndOne.instance_variable_set(:@aggregate, nil)
    detections
  end
end
