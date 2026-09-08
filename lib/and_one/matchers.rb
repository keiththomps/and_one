# frozen_string_literal: true

module AndOne
  # Minitest assertions for N+1 detection.
  #
  #   class MyTest < ActiveSupport::TestCase
  #     include AndOne::MinitestHelper
  #
  #     test "no N+1 queries" do
  #       assert_no_n_plus_one do
  #         Post.includes(:comments).each { |p| p.comments.to_a }
  #       end
  #     end
  #   end
  #
  module MinitestHelper
    # Assert that the block does NOT trigger any N+1 queries.
    def assert_no_n_plus_one(message = nil, &)
      detections = scan_for_n_plus_ones(&)

      return assert(true) if detections.empty?

      formatter = Formatter.new(
        backtrace_cleaner: AndOne.backtrace_cleaner || AndOne.send(:default_backtrace_cleaner)
      )
      detail = formatter.format(detections)
      summary = detections.map do |d|
        "#{d.count} queries to `#{d.table_name || "unknown"}` (expected 1)"
      end.join("; ")
      msg = message || "Expected no N+1 queries, but #{detections.size} detected: #{summary}\n#{detail}"
      flunk(msg)
    end

    # Assert that the block DOES trigger N+1 queries (useful for documenting known issues).
    def assert_n_plus_one(message = nil, &)
      detections = scan_for_n_plus_ones(&)

      if detections.empty?
        msg = message || "Expected N+1 queries, but none were detected"
        flunk(msg)
      end

      assert(true)
      detections
    end

    private

    def scan_for_n_plus_ones(&)
      AndOne.capture_for_test(&)
    end
  end

  # RSpec matcher for N+1 detection.
  #
  #   RSpec.describe "posts" do
  #     include AndOne::RSpecHelper
  #
  #     it "does not cause N+1 queries" do
  #       expect { Post.includes(:comments).each { |p| p.comments.to_a } }.not_to cause_n_plus_one
  #     end
  #   end
  #
  # Or with RSpec's matcher protocol directly:
  #
  #   require "and_one/rspec"  # auto-configures
  #
  module RSpecHelper
    def cause_n_plus_one
      CauseNPlusOne.new
    end

    class CauseNPlusOne
      def supports_block_expectations?
        true
      end

      def matches?(block)
        @detections = scan_block(block)
        @detections.any?
      end

      def failure_message
        "expected the block to cause N+1 queries, but none were detected"
      end

      def failure_message_when_negated
        formatter = AndOne::Formatter.new(
          backtrace_cleaner: AndOne.backtrace_cleaner || AndOne.send(:default_backtrace_cleaner)
        )
        detail = formatter.format(@detections)
        summary = @detections.map do |d|
          "#{d.count} queries to `#{d.table_name || "unknown"}` (expected 1)"
        end.join("; ")
        "expected no N+1 queries, but #{@detections.size} detected: #{summary}\n#{detail}"
      end

      def description
        "cause N+1 queries"
      end

      private

      def scan_block(block)
        AndOne.capture_for_test(&block)
      end
    end
  end
end
