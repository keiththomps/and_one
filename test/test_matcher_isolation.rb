# frozen_string_literal: true

require "test_helper"
require "timeout"

class TestMatcherIsolation < Minitest::Test
  include AndOneTestHelper
  include AndOne::MinitestHelper
  include AndOne::RSpecHelper

  def repeated_queries
    3.times do |index|
      ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT * FROM comments WHERE post_id = #{index}", name: "Comment Load")
    end
  end

  def test_successful_helpers_count_assertions
    before = assertions
    assert_no_n_plus_one { nil }
    assert_equal before + 1, assertions
    before = assertions
    assert_n_plus_one { repeated_queries }
    assert_equal before + 1, assertions
  end

  def test_nested_matchers_reject_before_running_block_and_preserve_outer_scan
    [nil, 42, []].each do |value|
      AndOne.scan do
        [->(&block) { assert_no_n_plus_one(&block) }, ->(&block) { cause_n_plus_one.matches?(block) }].each do |matcher|
          called = false
          error = assert_raises(ArgumentError) do
            matcher.call do
              called = true
              value
            end
          end
          assert_includes error.message, "inside an active scan"
          refute called
          assert AndOne.scanning?
        end
      end
      refute AndOne.scanning?
    end
  end

  def test_matcher_can_wrap_nested_application_scans
    [nil, 42, []].each do |value|
      assert_n_plus_one do
        AndOne.scan do
          repeated_queries
          value
        end
      end
      refute AndOne.scanning?
    end
  end

  def test_nonlocal_exit_releases_the_matcher_scan
    assert_equal :done, catch(:finished) {
      assert_no_n_plus_one do
        repeated_queries
        throw :finished, :done
      end
    }
    refute AndOne.scanning?
    assert_no_n_plus_one { nil }
  end

  def test_disabled_matchers_execute_blocks_but_ignore_their_return_values
    AndOne.enabled = false
    [nil, 42, [Object.new]].each do |value|
      called = false
      assert_no_n_plus_one do
        called = true
        value
      end
      assert called
      refute cause_n_plus_one.matches?(-> { value })
    end
  end

  def test_matchers_apply_ignores_without_reporting_or_consuming_deduplication
    AndOne.raise_on_detect = true
    AndOne.notifications_callback = ->(*) { flunk "matcher must not report" }
    assert_n_plus_one { repeated_queries }
    assert_equal 0, AndOne.aggregate.size

    AndOne.ignore_queries = [/comments/]
    assert_no_n_plus_one { repeated_queries }
    AndOne.ignore_queries = []
    File.write(File.join(@aggregate_tmpdir, "ignore"), "query:comments\n")
    AndOne.ignore_file_path = File.join(@aggregate_tmpdir, "ignore")
    AndOne.reload_ignore_file!
    refute cause_n_plus_one.matches?(-> { repeated_queries })
  end

  def test_settings_remain_unchanged_on_application_and_assertion_failures
    callback = ->(*) { flunk "matcher must not report" }
    AndOne.raise_on_detect = true
    AndOne.notifications_callback = callback
    assert_raises(RuntimeError) do
      assert_no_n_plus_one do
        assert AndOne.raise_on_detect
        assert_same callback, AndOne.notifications_callback
        raise "application failure"
      end
    end
    assert_raises(Minitest::Assertion) { assert_no_n_plus_one { repeated_queries } }
    assert AndOne.raise_on_detect
    assert_same callback, AndOne.notifications_callback
    refute AndOne.scanning?
  end

  def test_matcher_cannot_suppress_another_threads_enforcement_or_callback
    entered = Queue.new
    release = Queue.new
    callbacks = Queue.new
    AndOne.raise_on_detect = true
    callback = ->(*) { callbacks << Thread.current }
    AndOne.notifications_callback = callback
    worker = Thread.new do
      cause_n_plus_one.matches?(lambda do
        entered << true
        release.pop
        repeated_queries
      end)
    end

    Timeout.timeout(5) { entered.pop }
    assert AndOne.raise_on_detect
    assert_same callback, AndOne.notifications_callback
    assert_raises(AndOne::NPlus1Error) { AndOne.scan { repeated_queries } }
    assert_same Thread.current, Timeout.timeout(5) { callbacks.pop }
    release << true
    assert Timeout.timeout(5) { worker.value }
    assert callbacks.empty?
  ensure
    release << true
    worker&.kill
    worker&.join
  end
end
