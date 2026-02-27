# frozen_string_literal: true

require "test_helper"

class TestEnvThresholds < Minitest::Test
  include AndOneTestHelper

  def setup
    super
    seed_data!
    @original_rails_env = ENV["RAILS_ENV"]
    @original_rack_env = ENV["RACK_ENV"]
  end

  def teardown
    super
    Comment.delete_all
    Post.delete_all
    Author.delete_all
    ENV["RAILS_ENV"] = @original_rails_env
    ENV["RACK_ENV"] = @original_rack_env
    AndOne.env_thresholds = nil
  end

  def test_default_min_n_queries_is_2
    assert_equal 2, AndOne.send(:effective_min_n_queries)
  end

  def test_respects_global_min_n_queries
    AndOne.min_n_queries = 5
    assert_equal 5, AndOne.send(:effective_min_n_queries)
  end

  def test_env_threshold_overrides_global
    ENV["RAILS_ENV"] = "development"
    AndOne.min_n_queries = 2
    AndOne.env_thresholds = { "development" => 5, "test" => 2 }

    assert_equal 5, AndOne.send(:effective_min_n_queries)
  end

  def test_env_threshold_for_test
    ENV["RAILS_ENV"] = "test"
    AndOne.env_thresholds = { "development" => 5, "test" => 3 }

    assert_equal 3, AndOne.send(:effective_min_n_queries)
  end

  def test_falls_back_to_global_when_no_env_threshold
    ENV["RAILS_ENV"] = "staging"
    AndOne.min_n_queries = 4
    AndOne.env_thresholds = { "development" => 5, "test" => 2 }

    assert_equal 4, AndOne.send(:effective_min_n_queries)
  end

  def test_falls_back_to_global_when_no_env_thresholds_set
    ENV["RAILS_ENV"] = "development"
    AndOne.min_n_queries = 3
    AndOne.env_thresholds = nil

    assert_equal 3, AndOne.send(:effective_min_n_queries)
  end

  def test_uses_rack_env_when_rails_env_not_set
    ENV.delete("RAILS_ENV")
    ENV["RACK_ENV"] = "development"
    AndOne.env_thresholds = { "development" => 7 }

    assert_equal 7, AndOne.send(:effective_min_n_queries)
  end

  def test_env_threshold_affects_detection
    ENV["RAILS_ENV"] = "development"
    # We have 3 authors with 3 posts each, so 9 posts total => 9 comment queries
    # Setting threshold to 100 should suppress detection
    AndOne.env_thresholds = { "development" => 100 }

    detections = AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    assert_empty detections
  end

  def test_env_threshold_detects_when_above_threshold
    ENV["RAILS_ENV"] = "development"
    AndOne.env_thresholds = { "development" => 2 }

    detections = AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    assert detections.any?, "Expected N+1 detection with threshold of 2"
  end

  def test_symbol_keys_work_for_env_thresholds
    ENV["RAILS_ENV"] = "development"
    AndOne.env_thresholds = { development: 100 }

    assert_equal 100, AndOne.send(:effective_min_n_queries)
  end
end
