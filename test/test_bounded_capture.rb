# frozen_string_literal: true

require "test_helper"
require "timeout"

class TestBoundedCapture < Minitest::Test
  include AndOneTestHelper

  def emit(count)
    count.times do |i|
      ActiveSupport::Notifications.instrument("sql.active_record", name: "Load", sql: "SELECT * FROM posts WHERE id = #{i}")
    end
  end

  def test_large_scan_has_exact_count_and_bounded_samples
    AndOne.min_n_queries = 1000 # Thresholds must use counts, not sample lengths.
    detections = AndOne.capture_for_test { emit(10_000) }
    assert_equal 1, detections.size
    assert_equal 10_000, detections.first.count
    assert_equal AndOne::Detector::SAMPLE_LIMIT, detections.first.queries.size
    assert_equal 10_000, AndOne::JsonFormatter.new.format_hashes(detections).first[:query_count]
    AndOne.aggregate.record(detections.first)
    persisted = AndOne.aggregate.detections.values.first.detection
    assert_equal 10_000, persisted.count
    assert_equal detections.first.queries, persisted.queries
  end

  def test_mixed_shapes_at_same_stack_have_independent_counts
    detections = AndOne.capture_for_test do
      100.times do |i|
        table = i.even? ? "posts" : "comments"
        ActiveSupport::Notifications.instrument("sql.active_record", name: "Load", sql: "SELECT * FROM #{table} WHERE id = #{i}")
      end
    end
    assert_equal %w[comments posts], detections.map(&:table_name).sort
    assert_equal [50, 50], detections.map(&:count)
  end

  def test_query_ignore_sees_unsampled_literals_and_ignores_whole_group
    path = File.join(@aggregate_tmpdir, "ignore")
    File.write(path, "query:id = 99\n")
    AndOne.ignore_file_path = path
    AndOne.reload_ignore_file!
    assert_empty(AndOne.capture_for_test { emit(100) })
  end

  def test_configured_query_ignore_still_excludes_only_matching_events
    AndOne.ignore_queries = [/id = 99\z/]
    detections = AndOne.capture_for_test { emit(100) }
    assert_equal 99, detections.first.count
  end

  def test_callers_and_metadata_are_not_replaced_on_later_occurrences
    AndOne.scan
    detector = AndOne::ExecutionContext.active_detector
    first = nil
    3.times do
      emit(1)
      group = detector.instance_variable_get(:@groups).values.first
      first ||= [group.callers, group.metadata]
      assert_same first[0], group.callers
      assert_same first[1], group.metadata
    end
  ensure
    AndOne.finish
  end

  def test_one_subscriber_during_concurrent_scans_and_repeated_installation
    listeners = ActiveSupport::Notifications.notifier.listeners_for("sql.active_record").dup
    ready = Queue.new
    release = Queue.new
    threads = Array.new(12) do
      Thread.new do
        AndOne::SqlSubscriber.install!
        AndOne.capture_for_test do
          ready << true
          release.pop
          emit(20)
        end
      end
    end
    Timeout.timeout(10) { threads.size.times { ready.pop } }
    assert_equal listeners, ActiveSupport::Notifications.notifier.listeners_for("sql.active_record")
    threads.size.times { release << true }
    threads.each { |thread| assert_equal [20], thread.value.map(&:count) }
    assert_equal listeners, ActiveSupport::Notifications.notifier.listeners_for("sql.active_record")
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
    threads&.each(&:join)
  end
end
