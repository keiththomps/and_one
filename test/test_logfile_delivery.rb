# frozen_string_literal: true

require "test_helper"
require "timeout"

class TestLogfileDelivery < Minitest::Test
  include AndOneTestHelper

  def setup
    super
    @path = File.join(@aggregate_tmpdir, "findings.jsonl")
    @detection = AndOne::Detection.new(queries: ["SELECT * FROM posts WHERE id = 1"], count: 3)
    @writer = AndOne::LogfileWriter.new(path: @path, format: :json)
  end

  def test_format_failure_preserves_entries
    @writer.record([@detection])
    @writer.stub(:format_entries, ->(*) { raise ArgumentError, "bad format" }) do
      assert_raises(ArgumentError) { @writer.flush! }
    end
    @writer.flush!
    assert_equal [@detection.issue_id], logged_ids
  end

  def test_open_failure_preserves_entries
    @writer.record([@detection])
    File.stub(:open, ->(*) { raise Errno::EACCES }) do
      assert_raises(Errno::EACCES) { @writer.flush! }
    end
    @writer.flush!
    assert_equal [@detection.issue_id], logged_ids
  end

  def test_legacy_file_without_trailing_newline
    File.write(@path, '{"existing":true}')
    @writer.record([@detection])
    @writer.flush!
    assert_equal [nil, @detection.issue_id], logged_ids
  end

  def test_partial_write_is_rolled_back_and_retried
    File.write(@path, "{\"existing\":true}\n")
    @writer.record([@detection])
    File.open(@path, File::RDWR) do |file|
      original_write = file.method(:write)
      file.stub(:write, lambda { |output|
        original_write.call(output[0, 10])
        raise IOError, "disk full"
      }) do
        File.stub(:open, ->(*, &block) { block.call(file) }) do
          assert_raises(IOError) { @writer.flush! }
        end
      end
    end
    assert_equal "{\"existing\":true}\n", File.read(@path)
    @writer.flush!
    assert_equal [nil, @detection.issue_id], logged_ids
  end

  def test_concurrent_appends_survive_a_failed_flush
    @writer.record([@detection])
    entered = Queue.new
    release = Queue.new
    failure = Thread.new do
      @writer.stub(:format_entries, lambda { |*|
        entered << true
        release.pop
        raise IOError, "format failed"
      }) do
        assert_raises(IOError) { @writer.flush! }
      end
    end
    entered.pop
    other = AndOne::Detection.new(queries: ["SELECT * FROM comments"], count: 2)
    recorder = Thread.new { @writer.record([other]) }
    release << true
    [failure, recorder].each(&:value)
    @writer.flush!
    assert_equal [@detection.issue_id, other.issue_id].sort, logged_ids.sort
  end

  def test_actual_processes_append_complete_records
    %i[json text].each do |format|
      FileUtils.rm_f(@path)
      pids = 4.times.map do
        fork do
          writer = AndOne::LogfileWriter.new(path: @path, format: format)
          10.times do
            writer.record([@detection])
            writer.flush!
          end
          exit! 0
        end
      end
      pids.each { |pid| assert Process.wait2(pid).last.success? }
      content = File.read(@path)
      assert content.end_with?("\n")
      if format == :json
        assert_equal [@detection.issue_id] * 40, logged_ids
      else
        block = "#{@writer.send(:format_text, [@detection])}\n"
        assert_equal block * 40, content
      end
    end
  end

  def test_retry_queue_is_bounded_without_losing_accepted_entries
    @writer.record([@detection])
    others = AndOne::LogfileWriter::MAX_PENDING.times.map do |i|
      AndOne::Detection.new(queries: ["SELECT * FROM comments"], count: 2, issue_id: "issue-#{i}")
    end
    assert_raises(IOError) { @writer.record(others) }
    @writer.flush!
    assert_equal [@detection.issue_id], logged_ids
  end

  def test_reporting_retries_even_when_occurrence_is_deduplicated
    AndOne.logfile = @path
    AndOne.logfile_format = :json
    AndOne.raise_on_detect = true
    writer = AndOne.logfile_writer
    capture_io do
      writer.stub(:append, ->(*) { raise IOError, "unavailable" }) do
        assert_raises(AndOne::NPlus1Error) { AndOne.send(:report, [@detection]) }
      end
    end
    refute File.exist?(@path)
    assert_raises(AndOne::NPlus1Error) { AndOne.send(:report, [@detection]) }
    assert_equal [@detection.issue_id], logged_ids
    assert_raises(AndOne::NPlus1Error) { AndOne.send(:report, [@detection]) }
    assert_equal [@detection.issue_id], logged_ids
  end

  def test_callback_can_reenter_reporting_without_deadlock
    other = AndOne::Detection.new(queries: ["SELECT * FROM comments"], count: 2)
    calls = 0
    AndOne.notifications_callback = lambda do |*|
      calls += 1
      AndOne.send(:report, [other]) if calls == 1
    end
    Timeout.timeout(3) { AndOne.send(:report, [@detection]) }
    assert_equal 2, calls
  end

  def test_callback_errors_do_not_fail_application_or_suppress_enforcement
    AndOne.notifications_callback = ->(*) { raise "callback failed" }
    capture_io { AndOne.send(:report, [@detection]) }
    AndOne.raise_on_detect = true
    AndOne.aggregate.reset!
    capture_io do
      assert_raises(AndOne::NPlus1Error) { AndOne.send(:report, [@detection]) }
    end
  end

  def test_nested_n_plus_one_errors_are_not_swallowed
    AndOne.notifications_callback = ->(*) { raise AndOne::NPlus1Error, "nested scan" }
    assert_raises(AndOne::NPlus1Error) { AndOne.send(:report, [@detection]) }
  end

  private

  def logged_ids
    File.readlines(@path).map { |line| JSON.parse(line)["issue_id"] }
  end
end
