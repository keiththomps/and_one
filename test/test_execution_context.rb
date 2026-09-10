# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

class TestExecutionContext < Minitest::Test
  include AndOneTestHelper

  def emit
    3.times do
      ActiveSupport::Notifications.instrument("sql.active_record", name: "Load", sql: "SELECT * FROM posts WHERE id = 1")
    end
  end

  def test_interleaved_fibers_isolate_capture_and_pause
    first = Fiber.new do
      AndOne.capture_for_test do
        AndOne.pause do
          Fiber.yield
          assert AndOne.paused?
          emit
        end
        emit
      end
    end
    second = Fiber.new do
      AndOne.capture_for_test do
        refute AndOne.paused?
        2.times do |i|
          emit
          Fiber.yield if i.zero?
        end
      end
    end
    first.resume
    second.resume
    refute AndOne.scanning?
    assert_equal [3], first.resume.map(&:count)
    assert_equal [6], second.resume.map(&:count)
    refute AndOne.scanning?
  end

  def test_child_fiber_does_not_inherit_scan_and_cleans_up_on_throw
    detections = AndOne.capture_for_test do
      Fiber.new do
        refute AndOne.scanning?
        emit
        catch(:done) { AndOne.scan { AndOne.pause { throw :done } } }
        refute AndOne.scanning?
        refute AndOne.paused?
      end.resume
    end
    assert_empty detections
  end

  def test_child_thread_does_not_inherit_but_can_start_its_own_scan
    child = nil
    detections = AndOne.capture_for_test do
      child = Thread.new do
        refute AndOne.scanning?
        emit
        AndOne.capture_for_test { emit }
      end.value
    end
    assert_empty detections
    assert_equal [3], child.map(&:count)
  end

  def test_async_events_delivered_in_an_active_scan_are_not_misattributed
    detections = AndOne.capture_for_test do
      3.times do
        ActiveSupport::Notifications.instrument("sql.active_record", name: "Load", sql: "SELECT * FROM posts", async: true)
      end
    end
    assert_empty detections
  end

  def test_real_load_async_notification_boundaries
    fixture = File.expand_path("fixtures/async_capture.rb", __dir__)
    Dir.mktmpdir("and_one_async") do |root|
      output, status = Open3.capture2e(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), fixture, chdir: root)
      assert status.success?, output
      assert_includes output, "async worker execution; caller notification; excluded from scan"
      assert_includes output, "synchronous fallback captured"
    end
  end
end
