# frozen_string_literal: true

require "test_helper"
require "active_job"

# Minimal ActiveJob setup for testing (no Rails app needed)
ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.logger = Logger.new(nil)

class NplusOneJob < ActiveJob::Base
  include AndOne::ActiveJobHook

  self.queue_adapter = :inline

  def perform
    Post.all.each { |post| post.comments.to_a }
  end
end

class CleanJob < ActiveJob::Base
  include AndOne::ActiveJobHook

  self.queue_adapter = :inline

  def perform
    Post.includes(:comments).each { |post| post.comments.to_a }
  end
end

class ErrorJob < ActiveJob::Base
  include AndOne::ActiveJobHook

  self.queue_adapter = :inline

  def perform
    raise "job exploded"
  end
end

class TestActiveJobHook < Minitest::Test
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

  def test_detects_n_plus_one_in_job
    captured = nil
    AndOne.notifications_callback = lambda { |detections, _message|
      captured = detections
    }

    NplusOneJob.perform_now

    refute_nil captured
    assert captured.size >= 1
    assert_equal "comments", captured.first.table_name
  end

  def test_no_detection_with_includes_in_job
    captured = nil
    AndOne.notifications_callback = lambda { |detections, _message|
      captured = detections
    }

    CleanJob.perform_now

    assert_nil captured
  end

  def test_does_not_corrupt_job_error_backtrace
    error = assert_raises(RuntimeError) do
      ErrorJob.perform_now
    end

    assert_equal "job exploded", error.message
    assert(error.backtrace.any? { |line| line.include?("test_active_job_hook.rb") })
    refute AndOne.scanning?
  end

  def test_does_not_scan_when_disabled
    AndOne.enabled = false

    captured = nil
    AndOne.notifications_callback = lambda { |detections, _message|
      captured = detections
    }

    NplusOneJob.perform_now

    assert_nil captured
  end

  def test_raises_in_raise_mode
    AndOne.raise_on_detect = true

    assert_raises(AndOne::NPlus1Error) do
      NplusOneJob.perform_now
    end
  end
end
