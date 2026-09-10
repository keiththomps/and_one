# frozen_string_literal: true

require "test_helper"

class TestAggregate < Minitest::Test
  include AndOneTestHelper

  def setup
    super
    seed_data!
  end

  def teardown
    super
    Comment.delete_all
    Post.delete_all
    Author.delete_all
  end

  def test_only_reports_first_occurrence
    report_count = 0
    AndOne.notifications_callback = ->(*) { report_count += 1 }

    # Same application call site on both scans should report only once.
    2.times do
      AndOne.scan do
        Post.all.each { |post| post.comments.to_a }
      end
    end

    assert_equal 1, report_count
  end

  def test_reports_different_n_plus_ones
    report_count = 0
    AndOne.notifications_callback = ->(*) { report_count += 1 }

    # First unique N+1
    AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    # Different N+1
    AndOne.scan do
      Post.all.each(&:author)
    end

    assert_equal 2, report_count
  end

  def test_tracks_occurrence_count
    AndOne.notifications_callback = ->(*) {}

    3.times do
      AndOne.scan do
        Post.all.each { |post| post.comments.to_a }
      end
    end

    agg = AndOne.aggregate
    assert_equal 1, agg.size

    entry = agg.detections.values.first
    assert_equal 3, entry.occurrences
  end

  def test_summary_output
    AndOne.notifications_callback = ->(*) {}

    AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    summary = AndOne.aggregate.summary
    assert_includes summary, "1 unique repeated-query issue"
    assert_includes summary, "comments"
    assert_includes summary, "1 occurrence"
  end

  def test_reset
    AndOne.notifications_callback = ->(*) {}

    AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    refute AndOne.aggregate.empty?
    AndOne.aggregate.reset!
    assert AndOne.aggregate.empty?

    # After reset, should report again
    report_count = 0
    AndOne.notifications_callback = ->(*) { report_count += 1 }

    AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    assert_equal 1, report_count
  end

  def test_empty_summary
    summary = AndOne.aggregate.summary
    assert_includes summary, "No repeated-query findings detected"
  end
end
