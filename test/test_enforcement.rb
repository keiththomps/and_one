# frozen_string_literal: true

require "test_helper"

class TestEnforcement < Minitest::Test
  include AndOneTestHelper
  include AndOne::MinitestHelper

  def setup
    super
    seed_data!
    @reports = []
    AndOne.notifications_callback = ->(detections, _message) { @reports << detections }
    AndOne.raise_on_detect = true
  end

  def teardown
    Comment.delete_all
    Post.delete_all
    Author.delete_all
    super
  end

  def test_every_scan_raises_but_only_first_occurrence_is_reported
    2.times do
      error = assert_raises(AndOne::NPlus1Error) { AndOne.scan { load_comments } }
      assert_includes error.message, "comments"
    end

    assert_equal 1, @reports.size
    assert_equal 2, AndOne.aggregate.detections.values.first.occurrences
  end

  def test_non_raising_scan_does_not_suppress_later_failure
    AndOne.raise_on_detect = false
    AndOne.scan { load_comments }
    AndOne.raise_on_detect = true

    assert_raises(AndOne::NPlus1Error) { AndOne.scan { load_comments } }
  end

  def test_matcher_does_not_suppress_later_failure
    assert_n_plus_one { load_comments }

    assert_raises(AndOne::NPlus1Error) { AndOne.scan { load_comments } }
  end

  def test_persisted_aggregate_does_not_suppress_manual_finish_failure
    assert_raises(AndOne::NPlus1Error) { AndOne.scan { load_comments } }
    AndOne.instance_variable_set(:@aggregate, nil)
    AndOne.scan
    load_comments

    assert_raises(AndOne::NPlus1Error) { AndOne.finish }
    refute AndOne.scanning?
    assert_equal 1, @reports.size
  end

  def test_error_contains_known_and_new_findings
    assert_raises(AndOne::NPlus1Error) { AndOne.scan { load_comments } }
    error = assert_raises(AndOne::NPlus1Error) do
      AndOne.scan do
        load_comments
        Post.all.each(&:author)
      end
    end

    assert_includes error.message, "comments"
    assert_includes error.message, "authors"
    assert_equal ["authors"], @reports.last.map(&:table_name)
  end

  def test_ignore_file_excludes_findings_from_all_sinks_and_scan_results
    AndOne.ignore_file_path = File.join(@aggregate_tmpdir, ".and_one_ignore")
    File.write(AndOne.ignore_file_path, "query:comments\n")
    AndOne.reload_ignore_file!
    AndOne.logfile = File.join(@aggregate_tmpdir, "findings.log")
    AndOne.json_logging = true

    stdout, stderr = capture_io do
      assert_empty(AndOne.scan { load_comments })
      AndOne.scan
      load_comments
      assert_empty AndOne.finish
      AndOne.logfile_writer.flush!
    end

    assert_empty stdout
    assert_empty stderr
    assert_empty @reports
    assert AndOne.aggregate.empty?
    refute File.exist?(AndOne.logfile)
  end

  def test_caller_ignores_do_not_raise_or_report
    AndOne.ignore_callers = [/test_enforcement/]

    assert_empty(AndOne.scan { load_comments })
    assert_empty @reports
    assert AndOne.aggregate.empty?
  end

  private

  def load_comments
    Post.all.each { |post| post.comments.to_a }
  end
end
