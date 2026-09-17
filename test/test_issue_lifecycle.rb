# frozen_string_literal: true

require "test_helper"

class TestIssueLifecycle < Minitest::Test
  include AndOneTestHelper

  def setup
    super
    @aggregate = AndOne::Aggregate.new(path: @aggregate_tmpdir, strict: true)
    cost = AndOne::QueryCost.new
    3.times { cost.record(1.0) }
    @detection = AndOne::Detection.new(queries: ["SELECT * FROM posts WHERE author_id = 1"], count: 3, query_cost: cost,
                                       raw_caller_strings: ["app/services/feed.rb:12:in 'call'"])
    @aggregate.record(@detection)
  end

  def current
    @aggregate.detections.fetch(@detection.issue_id)
  end

  def test_resolution_preserves_observations_and_is_idempotent
    before = current
    result = @aggregate.resolve!(@detection.issue_id, note: "Regression test passed", revision: "abc123")
    assert_equal "resolved", result.status
    assert_equal before.occurrences, result.occurrences
    assert_equal before.first_seen_at, result.first_seen_at
    assert_equal before.last_seen_at, result.last_seen_at
    assert_equal before.query_cost.to_h, result.query_cost.to_h
    assert_equal "Regression test passed", result.resolution["note"]
    assert_equal "abc123", result.resolution["revision"]
    assert_equal 1, result.resolution["occurrences_at_resolution"]
    assert Time.iso8601(result.resolution["resolved_at"])

    again = @aggregate.resolve!(@detection.issue_id, note: "Should not overwrite")
    assert_equal result.resolution, again.resolution
    persisted = AndOne::Aggregate.new(path: @aggregate_tmpdir, strict: true).detections.fetch(@detection.issue_id)
    assert_equal result.resolution, persisted.resolution
    assert_equal "resolved", persisted.status
  end

  def test_recurrence_reopens_and_becomes_reportable_once
    resolution = @aggregate.resolve!(@detection.issue_id, note: "Verified").resolution
    assert @aggregate.record(@detection)
    assert_equal "open", current.status
    assert_equal "observed", current.reopen_reason
    assert current.reopened_at
    assert_equal resolution, current.resolution
    assert_equal 2, current.occurrences
    assert_equal 6, current.query_cost.query_count
    refute @aggregate.record(@detection)
    assert_equal 3, current.occurrences
  end

  def test_manual_reopen_is_idempotent_and_does_not_invent_an_observation
    @aggregate.resolve!(@detection.issue_id, note: "Verified")
    result = @aggregate.reopen!(@detection.issue_id)
    assert_equal "open", result.status
    assert_equal "manual", result.reopen_reason
    assert_equal 1, result.occurrences
    assert_equal result.reopened_at, @aggregate.reopen!(@detection.issue_id).reopened_at
  end

  def test_a_new_location_does_not_inherit_resolution
    @aggregate.resolve!(@detection.issue_id, note: "Verified")
    moved = AndOne::Detection.new(queries: @detection.queries, count: 3,
                                  raw_caller_strings: ["app/services/feed.rb:14:in 'call'"])
    assert @aggregate.record(moved)
    assert_equal "open", @aggregate.detections.fetch(moved.issue_id).status
    assert_equal "resolved", current.status
  end

  def test_legacy_entries_are_open_and_invalid_state_is_not_silently_discarded
    file = File.join(@aggregate_tmpdir, "aggregate.json")
    data = JSON.parse(File.read(file))
    data.values.first.delete("status")
    File.write(file, JSON.generate(data))
    assert_equal "open", current.status

    data.values.first["status"] = "bogus"
    File.write(file, JSON.generate(data))
    assert_raises(IOError) { @aggregate.resolve!(@detection.issue_id, note: "Verified") }
    assert_equal data, JSON.parse(File.read(file))
  end

  def test_notes_are_bounded_and_unknown_issues_and_empty_notes_are_errors
    entry = @aggregate.resolve!(@detection.issue_id, note: "é" * 3000, revision: "x" * 200)
    assert_operator entry.resolution["note"].bytesize, :<=, 2048
    assert entry.resolution["note"].valid_encoding?
    assert_equal 128, entry.resolution["revision"].bytesize
    assert_raises(AndOne::Aggregate::IssueNotFound) { @aggregate.resolve!("unknown", note: "Verified") }
    assert_raises(AndOne::Aggregate::IssueNotFound) { @aggregate.reopen!("unknown") }
    assert_raises(ArgumentError) { @aggregate.resolve!(@detection.issue_id, note: " ") }
  end

  def test_operator_mutation_failures_are_not_swallowed_in_non_strict_mode
    store = Object.new
    def store.transaction
      raise IOError, "storage unavailable"
    end
    aggregate = AndOne::Aggregate.new(store: store)
    assert_raises(IOError) { aggregate.resolve!(@detection.issue_id, note: "Verified") }
    assert_raises(IOError) { aggregate.reopen!(@detection.issue_id) }
  end

  def test_reset_does_not_leave_resolution_tombstones
    @aggregate.resolve!(@detection.issue_id, note: "Verified")
    @aggregate.reset!
    assert @aggregate.record(@detection)
    assert_equal "open", current.status
    assert_nil current.resolution
  end

  def test_cooperating_processes_preserve_counts_and_resolution
    skip "fork unavailable" unless Process.respond_to?(:fork)

    pid = fork do
      other = AndOne::Aggregate.new(path: @aggregate_tmpdir, strict: true)
      10.times { other.record(@detection) }
      exit! 0
    end
    @aggregate.resolve!(@detection.issue_id, note: "Verified")
    _pid, status = Process.wait2(pid)
    assert_predicate status, :success?
    @aggregate.record(@detection)
    assert_equal 12, current.occurrences
    assert_equal "open", current.status
    assert_equal "Verified", current.resolution["note"]
    assert_operator current.resolution["occurrences_at_resolution"], :<=, 11
  end
end
