# frozen_string_literal: true

require "test_helper"

class TestConsole < Minitest::Test
  include AndOneTestHelper

  def setup
    super
    seed_data!
    AndOne::Console.deactivate! if AndOne::Console.active?
  end

  def teardown
    super
    AndOne::Console.deactivate! if AndOne::Console.active?
    Comment.delete_all
    Post.delete_all
    Author.delete_all
  end

  def test_activate_starts_scanning
    AndOne::Console.activate!

    assert AndOne::Console.active?
    assert AndOne.scanning?
  end

  def test_deactivate_stops_scanning
    AndOne::Console.activate!
    AndOne::Console.deactivate!

    refute AndOne::Console.active?
    refute AndOne.scanning?
  end

  def test_activate_sets_raise_on_detect_false
    AndOne.raise_on_detect = true
    AndOne::Console.activate!

    refute AndOne.raise_on_detect, "Console mode should never raise"
  end

  def test_deactivate_restores_raise_on_detect
    AndOne.raise_on_detect = true
    AndOne::Console.activate!
    AndOne::Console.deactivate!

    assert AndOne.raise_on_detect, "Should restore original raise_on_detect"
  end

  def test_activate_is_idempotent
    AndOne::Console.activate!
    AndOne::Console.activate!

    assert AndOne::Console.active?
    assert AndOne.scanning?

    AndOne::Console.deactivate!
    refute AndOne::Console.active?
  end

  def test_deactivate_is_idempotent
    AndOne::Console.deactivate!
    AndOne::Console.deactivate!

    refute AndOne::Console.active?
  end

  def test_cycle_scan_detects_n_plus_one
    captured = nil
    AndOne.notifications_callback = ->(dets, msg) { captured = dets }

    AndOne::Console.activate!

    # Trigger an N+1
    Post.all.each { |post| post.comments.to_a }

    # Simulate end-of-command cycle
    AndOne::Console.send(:cycle_scan)

    refute_nil captured, "Expected N+1 detection during console scan"
    assert captured.any? { |d| d.table_name == "comments" }

    # Should still be scanning for the next command
    assert AndOne.scanning?
  end

  def test_cycle_scan_resets_between_commands
    captured_calls = []
    AndOne.notifications_callback = ->(dets, msg) { captured_calls << dets }

    AndOne::Console.activate!

    # First "command" — triggers N+1
    Post.all.each { |post| post.comments.to_a }
    AndOne::Console.send(:cycle_scan)

    # Second "command" — no N+1
    Post.includes(:comments).each { |post| post.comments.to_a }
    AndOne::Console.send(:cycle_scan)

    # First command should have reported, second should not
    assert_equal 1, captured_calls.size
  end
end
