# frozen_string_literal: true

require "test_helper"

class TestQueryCost < Minitest::Test
  include AndOneTestHelper

  SQL = "SELECT * FROM posts WHERE id = 1"

  def test_monotonic_notification_timings_and_cache_policy
    AndOne.notifications_callback = ->(*) {}
    payloads = [
      { sql: SQL }, { sql: SQL },
      { sql: SQL, cached: true }, { sql: SQL, async: true },
      { sql: SQL, name: "SCHEMA" }, { sql: "UPDATE posts SET title = 'x'" }
    ]
    detections = AndOne.scan do
      payloads.each_with_index do |payload, index|
        ActiveSupport::Notifications.publish("sql.active_record", 10.0, 10.0 + ((index + 1) / 8.0), "test", payload)
      end
    end

    assert_equal 1, detections.size
    cost = detections.first.query_cost
    assert_equal 2, detections.first.count
    assert_equal 2, cost.query_count
    assert_equal 2, cost.timed_query_count
    assert_equal 375.0, cost.total_duration_ms
    assert_equal 125.0, cost.min_duration_ms
    assert_equal 250.0, cost.max_duration_ms
    assert_equal 187.5, cost.to_h["mean_duration_ms"]
    assert_equal "excluded", cost.to_h["cached_queries"]
    assert_equal cost.to_h, JSON.parse(AndOne::JsonFormatter.new.format(detections))["query_cost"]
  end

  def test_instrumented_events_have_real_monotonic_measurements
    AndOne.notifications_callback = ->(*) {}
    detections = AndOne.scan do
      2.times { ActiveSupport::Notifications.instrument("sql.active_record", sql: SQL) { SQL.size } }
    end
    cost = detections.first.query_cost
    assert_equal 2, cost.timed_query_count
    assert_operator cost.total_duration_ms, :>=, 0
    assert_operator cost.max_duration_ms, :>=, cost.min_duration_ms
  end

  def test_missing_invalid_and_zero_timings
    cost = AndOne::QueryCost.new
    [nil, -1, Float::NAN, Float::INFINITY, "secret", 0.0, 2.0].each { |duration| cost.record(duration) }

    assert_equal 7, cost.query_count
    assert_equal 2, cost.timed_query_count
    assert_equal 2.0, cost.total_duration_ms
    assert_equal 0.0, cost.min_duration_ms
    assert_equal 1.0, cost.to_h["mean_duration_ms"]
    refute_includes JSON.generate(cost.to_h), "secret"
  end

  def test_unmeasured_direct_recording_is_not_zero_cost
    detector = AndOne::Detector.new
    2.times { detector.record(sql: SQL) }
    cost = detector.finish.first.query_cost

    assert_equal 2, cost.query_count
    assert_equal 0, cost.timed_query_count
    assert_nil cost.to_h["mean_duration_ms"]
    assert_nil cost.min_duration_ms
  end

  def test_cost_retention_is_constant_and_ignores_and_thresholds_are_unchanged
    detector = AndOne::Detector.new(min_n_queries: 3, ignore_queries: [/ignored/])
    100.times do
      detector.record({ sql: SQL }, duration_ms: 1.0)
      detector.record({ sql: "SELECT * FROM ignored" }, duration_ms: 10.0)
    end
    detection = detector.finish.fetch(0)
    assert_equal 1, detector.detections.size
    assert_equal 100, detection.count
    assert_equal 100.0, detection.query_cost.total_duration_ms
    assert_equal 5, detection.queries.size
    assert_equal 8, detection.query_cost.to_h.size

    below = AndOne::Detector.new(min_n_queries: 3)
    2.times { below.record({ sql: SQL }, duration_ms: 10.0) }
    assert_empty below.finish
  end

  def test_repeated_occurrences_round_trip_in_both_stores
    [AndOne::Aggregate.new, AndOne::Aggregate.new(path: @aggregate_tmpdir, strict: true)].each do |aggregate|
      assert aggregate.record(detection("same", [1.0, 3.0]))
      refute aggregate.record(detection("same", [6.0, 10.0, nil]))
      entry = aggregate.detections.fetch("same")
      assert_equal 2, entry.occurrences
      assert_equal 2, entry.query_cost.occurrences
      assert_equal 5, entry.query_cost.query_count
      assert_equal 4, entry.query_cost.timed_query_count
      assert_equal 20.0, entry.query_cost.total_duration_ms
      assert_equal 1.0, entry.query_cost.min_duration_ms
      assert_equal 10.0, entry.query_cost.max_duration_ms
      assert_equal 5.0, entry.query_cost.to_h["mean_duration_ms"]
      assert_equal 4.0, entry.detection.query_cost.total_duration_ms
      json = JSON.parse(AndOne::JsonFormatter.new.format_aggregate(aggregate.detections)).first
      assert_equal 2, json["occurrences"]
      assert_equal entry.query_cost.to_h, json["cumulative_query_cost"]
    end
    reopened = AndOne::Aggregate.new(path: @aggregate_tmpdir, strict: true)
    assert_equal 20.0, reopened.detections.fetch("same").query_cost.total_duration_ms
  end

  def test_historical_entries_remain_unknown_and_new_coverage_is_explicit
    store = AndOne::AggregateStore::Memory.new
    aggregate = AndOne::Aggregate.new(store: store)
    aggregate.record(detection("old", nil))
    # Model documents written before either cost field existed.
    store.transaction do |data|
      data.fetch("old").delete("query_cost")
      data.fetch("old").fetch("detection").delete("query_cost")
    end
    assert_nil aggregate.detections.fetch("old").query_cost
    aggregate.record(detection("old", [4.0, 6.0]))
    entry = aggregate.detections.fetch("old")
    assert_equal 2, entry.occurrences
    assert_equal 1, entry.query_cost.occurrences
    assert_equal 2, entry.query_cost.query_count
    assert_equal 10.0, entry.query_cost.total_duration_ms
  end

  def test_dashboard_sorts_each_metric_and_places_unknown_costs_last
    AndOne.aggregate.record(detection("historical", nil))
    AndOne.aggregate.record(detection("expensive", [100.0, 200.0]))
    AndOne.aggregate.record(detection("many", [1.0] * 10))
    3.times { AndOne.aggregate.record(detection("frequent", [1.0, 1.0])) }

    ui = AndOne::DevUI.new(->(_) { flunk "unexpected passthrough" })
    { "time" => %w[expensive many frequent historical],
      "queries" => %w[many frequent expensive historical],
      "occurrences" => %w[frequent expensive historical many],
      "invalid" => %w[expensive many frequent historical] }.each do |sort, expected|
      html = ui.call("PATH_INFO" => "/__and_one", "QUERY_STRING" => "sort=#{sort}")[2].first
      assert_equal expected, html.scan(/issue_id: (\w+)/).flatten
      assert_includes html, "300.000 ms observed"
      assert_includes html, "Unknown (historical)"
      assert_includes html, "not estimated savings"
      assert_includes html, "Cache hits and async queries excluded"
    end
  end

  private

  def detection(issue_id, durations)
    cost = AndOne::QueryCost.new if durations
    durations&.each { |duration| cost.record(duration) }
    AndOne::Detection.new(queries: [SQL], count: durations&.size || 2, issue_id: issue_id, query_cost: cost)
  end
end
