# frozen_string_literal: true

require "test_helper"

class TestMiddleware < Minitest::Test
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

  def test_middleware_does_not_corrupt_error_backtrace
    app = ->(_env) { raise "something broke" }
    middleware = AndOne::Middleware.new(app)

    error = assert_raises(RuntimeError) do
      middleware.call({})
    end

    assert_equal "something broke", error.message
    # Backtrace should point to THIS test file, not to and_one internals
    assert(error.backtrace.any? { |line| line.include?("test_middleware.rb") })
  end

  def test_middleware_passes_through_when_disabled
    AndOne.enabled = false
    app_called = false
    app = lambda { |_env|
      app_called = true
      [200, {}, ["OK"]]
    }

    middleware = AndOne::Middleware.new(app)
    middleware.call({})

    assert app_called
    refute AndOne.scanning?
  end

  def test_middleware_cleans_up_after_error
    app = ->(_env) { raise "boom" }
    middleware = AndOne::Middleware.new(app)

    assert_raises(RuntimeError) { middleware.call({}) }

    # Should not be left in scanning state
    refute AndOne.scanning?
  end
end
