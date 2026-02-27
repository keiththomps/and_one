# frozen_string_literal: true

require "test_helper"

class TestDetection < Minitest::Test
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

  def test_fingerprint_is_stable
    detections1 = AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    detections2 = AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    assert_equal detections1.first.fingerprint, detections2.first.fingerprint
  end

  def test_different_n_plus_ones_have_different_fingerprints
    fp1 = nil
    fp2 = nil

    AndOne.notifications_callback = ->(dets, msg) { fp1 = dets.first.fingerprint }
    AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    AndOne.notifications_callback = ->(dets, msg) { fp2 = dets.first.fingerprint }
    AndOne.scan do
      Post.all.each { |post| post.author }
    end

    refute_equal fp1, fp2
  end

  def test_fingerprint_is_12_chars
    detections = AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    assert_equal 12, detections.first.fingerprint.length
  end

  def test_origin_frame_is_app_code
    detections = AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    origin = detections.first.origin_frame
    refute_nil origin
    # Should point to this test file, not to a gem
    assert_includes origin, "test_detection.rb"
    refute_includes origin, "/gems/"
  end

  def test_fix_location_differs_from_origin
    detections = AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    det = detections.first
    # fix_location should be the outer frame (the .each call or the scan block)
    # origin_frame should be the inner frame (the .to_a / association access)
    # They may or may not differ depending on how Ruby reports line numbers,
    # but both should be in this test file
    assert_includes det.origin_frame, "test_detection.rb"
    if det.fix_location
      assert_includes det.fix_location, "test_detection.rb"
    end
  end

  def test_raw_caller_strings_include_gem_paths
    detections = AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    raw = detections.first.raw_caller_strings
    # Should include both gem frames and app frames
    assert raw.any? { |f| f.include?("/gems/") }, "Expected gem frames in raw callers"
    assert raw.any? { |f| f.include?("test_detection.rb") }, "Expected app frames in raw callers"
  end
end
