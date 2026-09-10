# frozen_string_literal: true

require "test_helper"

class TestQueryBudgets < Minitest::Test
  include AndOneTestHelper
  include AndOne::MinitestHelper

  def setup
    super
    seed_data!
  end

  def teardown
    Comment.delete_all
    Post.delete_all
    Author.delete_all
    super
  end

  def load_posts(size, preload: false)
    scope = Post.limit(size)
    scope = scope.preload(:comments) if preload
    scope.each { |post| post.comments.to_a }
  end

  def test_fixed_budget_and_growth_for_preloaded_workloads
    before = assertions
    result = assert_query_budget(max: 2) { load_posts(9, preload: true) }
    assert_equal before + 1, assertions
    assert_equal 2, result.count
    assert_equal 0, result.cached_count
    result = assert_query_growth(small: -> { load_posts(2, preload: true) }, large: -> { load_posts(9, preload: true) })
    assert_equal [2, 2, 0], [result.small.count, result.large.count, result.growth]
  end

  def test_n_plus_one_fails_budget_and_growth_with_counts_and_locations
    error = assert_raises(Minitest::Assertion) { assert_query_budget(max: 2) { load_posts(9) } }
    assert_includes error.message, "10 executed queries"
    assert_includes error.message, "test_query_budgets.rb:"
    error = assert_raises(Minitest::Assertion) do
      assert_query_growth(small: -> { load_posts(2) }, large: -> { load_posts(9) }, max_growth: 1)
    end
    assert_includes error.message, "query growth 7 (maximum 1)"
    assert_includes error.message, "small: 3 executed queries"
    assert_includes error.message, "large: 10 executed queries"
  end

  def test_setup_is_excluded_and_workloads_run_once_in_order
    calls = []
    post = Post.create!(title: "outside measurement")
    result = assert_query_growth(
      small: lambda {
        calls << :small
        Post.find(post.id)
      },
      large: lambda {
        calls << :large
        Post.find(post.id)
      }
    )
    assert_equal %i[small large], calls
    assert_equal [1, 1], [result.small.count, result.large.count]
  end

  def test_cache_hits_excluded_without_changing_cache_state
    id = Post.minimum(:id)
    ActiveRecord::Base.cache do
      Post.connection.clear_query_cache
      result = assert_query_budget(max: 1) { 3.times { Post.find(id) } }
      assert_equal [1, 2], [result.count, result.cached_count]
      warm = assert_query_budget(max: 0) { Post.find(id) }
      assert_equal [0, 1], [warm.count, warm.cached_count]
      ActiveRecord::Base.uncached do
        cold = assert_query_budget(max: 3) { 3.times { Post.find(id) } }
        assert_equal [3, 0], [cold.count, cold.cached_count]
      end
    end
  end

  def test_growth_preserves_warm_cache_and_exposes_each_samples_cache_hits
    id = Post.minimum(:id)
    ActiveRecord::Base.cache do
      Post.connection.clear_query_cache
      result = assert_query_growth(small: -> { Post.find(id) }, large: -> { 3.times { Post.find(id) } })
      assert_equal [1, 0], [result.small.count, result.small.cached_count]
      assert_equal [0, 3], [result.large.count, result.large.cached_count]
      assert_equal(-1, result.growth)
    end
  end

  def test_nested_captures_are_inclusive_and_independent
    inner = nil
    outer = assert_query_budget(max: 3) do
      Post.count
      inner = assert_query_budget(max: 1) { Post.count }
      Post.count
    end
    assert_equal 1, inner.count
    assert_equal 3, outer.count
    assert_nil AndOne::ExecutionContext[:and_one_query_captures]
  end

  def test_nested_assertion_failure_and_nonlocal_exit_restore_capture
    outer = assert_query_budget(max: 2) do
      assert_raises(Minitest::Assertion) { assert_query_budget(max: 0) { Post.count } }
      assert_equal :done, catch(:done) { AndOne::QueryCapture.capture { throw :done, :done } }
      Post.count
    end
    assert_equal 2, outer.count
    assert_raises(RuntimeError) { AndOne::QueryCapture.capture { raise "application failure" } }
    assert_nil AndOne::ExecutionContext[:and_one_query_captures]
  end

  def test_explicit_measurements_ignore_detection_settings_and_do_not_report
    callback = ->(*) { flunk "unexpected reporting" }
    AndOne.enabled = false
    AndOne.raise_on_detect = true
    AndOne.notifications_callback = callback
    AndOne.ignore_queries = [/./]
    AndOne.pause do
      result = assert_query_budget(max: 3) { 3.times { Post.count } }
      assert_equal 3, result.count
      assert AndOne.paused?
    end
    refute AndOne.enabled?
    assert AndOne.raise_on_detect
    assert_same callback, AndOne.notifications_callback
    assert_empty AndOne.aggregate.detections
  end

  def test_capture_does_not_change_existing_scan_enforcement
    AndOne.raise_on_detect = true
    assert_raises(AndOne::NPlus1Error) do
      AndOne.scan { assert_query_budget(max: 3) { 3.times { Post.count } } }
    end
    assert_nil AndOne::ExecutionContext[:and_one_query_captures]
    refute AndOne.scanning?
  end

  def test_invalid_inputs_fail_before_any_workload_runs
    called = false
    [-1, 1.5, nil].each do |limit|
      assert_raises(ArgumentError) { assert_query_budget(max: limit) { called = true } }
      assert_raises(ArgumentError) do
        assert_query_growth(small: -> { called = true }, large: -> {}, max_growth: limit)
      end
    end
    assert_raises(ArgumentError) { assert_query_growth(small: -> { called = true }, large: nil) }
    assert_raises(ArgumentError) { assert_query_budget(max: 1) }
    refute called
  end

  def test_notification_policy_and_bounded_secret_free_diagnostics
    result = AndOne::QueryCapture.capture do
      20.times do
        ActiveSupport::Notifications.instrument("sql.active_record", sql: "INSERT INTO secrets VALUES ('sentinel')", name: "Write")
      end
      ActiveSupport::Notifications.instrument("sql.active_record", sql: "BEGIN", name: "TRANSACTION")
      ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT schema", name: "SCHEMA")
      ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT 1", cached: true)
    end
    assert_equal 21, result.count
    assert_equal 1, result.cached_count
    assert_operator result.locations.size, :<=, 5
    assert(result.locations.all? { |location| location.bytesize <= 300 })
    refute_includes result.inspect, "sentinel"
  end

  def test_capture_is_fiber_and_thread_local
    result = AndOne::QueryCapture.capture do
      work = -> { ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT 1") }
      Fiber.new { work.call }.resume
      Thread.new { work.call }.value
      work.call
    end
    assert_equal 1, result.count
  end
end
