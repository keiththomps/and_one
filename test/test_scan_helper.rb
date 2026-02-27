# frozen_string_literal: true

require "test_helper"

class TestScanHelper < Minitest::Test
  include AndOneTestHelper

  class FakeMiddleware
    include AndOne::ScanHelper

    def run(&block)
      and_one_wrap(&block)
    end
  end

  def setup
    super
    seed_data!
    @mw = FakeMiddleware.new
  end

  def teardown
    super
    Comment.delete_all
    Post.delete_all
    Author.delete_all
  end

  def test_returns_block_value
    result = @mw.run { 42 }
    assert_equal 42, result
  end

  def test_cleans_up_on_error
    assert_raises(RuntimeError) { @mw.run { raise "boom" } }
    refute AndOne.scanning?
  end

  def test_nested_wrap_passes_through
    report_count = 0
    AndOne.notifications_callback = ->(*) { report_count += 1 }

    @mw.run do
      # Inner wrap should see we're already scanning and just yield
      @mw.run do
        Post.all.each { |post| post.comments.to_a }
      end
    end

    # Only reported once by the outer wrap
    assert_equal 1, report_count
  end
end
