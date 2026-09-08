# frozen_string_literal: true

require "test_helper"

class TestScanLifecycle < Minitest::Test
  include AndOneTestHelper

  class Wrapper
    include AndOne::ScanHelper

    def call(&)
      and_one_wrap(&)
    end
  end

  def setup
    super
    @listeners = sql_listeners
    @reports = []
    AndOne.notifications_callback = ->(*) { @reports << true }
  end

  def teardown
    refute AndOne.scanning?
    assert_equal @listeners, sql_listeners
    super
  end

  def test_owned_wrappers_release_on_normal_completion
    wrappers.each do |wrapper|
      wrapper.call { record_queries }
      assert_released
    end
  end

  def test_owned_wrappers_release_on_throw_without_reporting
    wrappers.each do |wrapper|
      result = catch(:done) do
        wrapper.call do
          record_queries
          throw :done, :thrown
        end
      end
      assert_equal :thrown, result
      assert_released
    end
    assert_empty @reports
  end

  def test_owned_wrappers_release_on_return_without_reporting
    wrappers.each do |wrapper|
      assert_equal :returned, return_from(wrapper)
      assert_released
    end
    assert_empty @reports
  end

  def test_owned_wrappers_release_on_break_without_reporting
    wrappers.each do |wrapper|
      result = wrapper.call do
        record_queries
        break :broken
      end
      assert_equal :broken, result
      assert_released
    end
    assert_empty @reports
  end

  def test_owned_wrappers_preserve_original_exception_and_backtrace
    wrappers.each do |wrapper|
      original = RuntimeError.new("application failure")
      original.set_backtrace(["app/service.rb:42"])
      caught = assert_raises(RuntimeError) do
        wrapper.call do
          record_queries
          raise original
        end
      end
      assert_same original, caught
      assert_equal ["app/service.rb:42"], caught.backtrace
      assert_released
    end
    assert_empty @reports
  end

  def test_nested_wrappers_leave_outer_scan_and_pause_intact
    AndOne.scan do
      outer = Thread.current[:and_one_detector]
      AndOne.pause do
        wrappers.each do |wrapper|
          catch(:done) { wrapper.call { throw :done } }
          assert_same outer, Thread.current[:and_one_detector]
          assert AndOne.paused?
        end
      end
    end
  end

  def test_finishing_and_replacing_scan_does_not_let_outer_wrapper_stop_replacement
    wrappers.each do |wrapper|
      wrapper.call do
        AndOne.finish
        AndOne.scan
      end
      assert AndOne.scanning?
      assert_empty AndOne.finish
      assert_released
    end
  end

  def test_manual_finish_releases_even_when_analysis_raises
    AndOne.scan
    owned = Thread.current[:and_one_detector]
    owned.define_singleton_method(:analyze) { raise "analysis failure" }

    assert_raises(RuntimeError) { AndOne.finish }
    assert_nil owned.instance_variable_get(:@subscriber)
    assert_released
    assert_empty AndOne.finish
  end

  def test_nested_pauses_restore_outer_state
    AndOne.scan do
      AndOne.pause do
        AndOne.pause { assert AndOne.paused? }
        assert AndOne.paused?
      end
      refute AndOne.paused?
      AndOne.pause
      AndOne.pause { assert AndOne.paused? }
      assert AndOne.paused?
      AndOne.resume
      refute AndOne.paused?
    end
  end

  def test_pause_outside_scan_restores_prior_state_on_all_exits
    refute AndOne.paused?
    AndOne.pause { assert AndOne.paused? }
    refute AndOne.paused?
    catch(:done) { AndOne.pause { throw :done } }
    refute AndOne.paused?
    assert_raises(RuntimeError) { AndOne.pause { raise "failure" } }
    refute AndOne.paused?
    AndOne.pause
    assert_raises(RuntimeError) { AndOne.pause { raise "failure" } }
    assert AndOne.paused?
    AndOne.resume
  end

  private

  def wrappers
    [
      ->(&block) { AndOne.scan(&block) },
      Wrapper.new,
      lambda do |&block|
        app = lambda do |_env|
          block.call
          [200, {}, ["OK"]]
        end
        AndOne::Middleware.new(app).call({})
      end
    ]
  end

  def return_from(wrapper)
    wrapper.call do
      record_queries
      return :returned
    end
  end

  def record_queries
    2.times do
      ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT * FROM comments WHERE post_id = 1", name: "Load")
    end
  end

  def assert_released
    refute AndOne.scanning?
    refute AndOne.paused?
    assert_equal @listeners, sql_listeners
  end

  def sql_listeners
    ActiveSupport::Notifications.notifier.listeners_for("sql.active_record").dup
  end
end
