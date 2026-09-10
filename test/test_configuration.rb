# frozen_string_literal: true

require "test_helper"

class TestConfiguration < Minitest::Test
  include AndOneTestHelper

  def test_aggregate_path_change_rebuilds_service
    previous = AndOne.aggregate
    AndOne.aggregate_path = File.join(@aggregate_tmpdir, "other")
    refute_same previous, AndOne.aggregate
    refute File.exist?(AndOne.aggregate_path), "storage is lazy"
    AndOne.aggregate.record(AndOne::Detection.new(queries: ["SELECT * FROM posts"], count: 2))
    assert File.directory?(AndOne.aggregate_path)
  end

  def test_ignore_path_change_rebuilds_service
    previous = AndOne.ignore_list
    AndOne.ignore_file_path = File.join(@aggregate_tmpdir, "ignore")
    refute_same previous, AndOne.ignore_list
  end

  def test_logfile_changes_flush_previous_writer_and_rebuild
    path = File.join(@aggregate_tmpdir, "original.jsonl")
    AndOne.logfile = path
    AndOne.logfile_format = :json
    original = AndOne.logfile_writer
    original.record([AndOne::Detection.new(queries: ["SELECT * FROM posts"], count: 2)])
    AndOne.logfile_format = :text
    refute_same original, AndOne.logfile_writer
    assert_equal "n_plus_one_detected", JSON.parse(File.read(path))["event"]
    previous = AndOne.logfile_writer
    AndOne.logfile = File.join(@aggregate_tmpdir, "other.log")
    refute_same previous, AndOne.logfile_writer
    AndOne.logfile = nil
    assert_nil AndOne.logfile_writer
  end

  def test_failed_flush_rejects_configuration_change
    path = File.join(@aggregate_tmpdir, "original.log")
    AndOne.logfile = path
    original = AndOne.logfile_writer
    original.stub(:flush!, -> { raise IOError, "unavailable" }) do
      assert_raises(IOError) { AndOne.logfile = nil }
    end
    assert_equal path, AndOne.logfile
    assert_same original, AndOne.logfile_writer
  end
end
