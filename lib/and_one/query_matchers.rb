# frozen_string_literal: true

module AndOne
  module MinitestHelper
    def assert_query_budget(max:, message: nil, &)
      QueryCapture.validate_limit!(max)
      result = QueryCapture.capture(&)
      assert result.count <= max, message || "Expected at most #{max} executed queries; #{result.summary}"
      result
    end

    def assert_query_growth(small:, large:, max_growth: 0, message: nil)
      result = QueryGrowth.new(small: small, large: large, max_growth: max_growth)
      assert result.within_limit?, message || "Expected bounded #{result.summary}"
      result
    end
  end

  module RSpecHelper
    def stay_within_query_budget(max)
      QueryBudgetMatcher.new(max)
    end

    # Value expectation: expect(small: -> { ... }, large: -> { ... }).to ...
    def stay_within_query_growth(max_growth = 0)
      QueryGrowthMatcher.new(max_growth)
    end

    class QueryBudgetMatcher
      attr_reader :result

      def initialize(max)
        QueryCapture.validate_limit!(max)
        @max = max
      end

      def supports_block_expectations?
        true
      end

      def supports_value_expectations?
        false
      end

      def matches?(block)
        @result = QueryCapture.capture(&block)
        result.count <= @max
      end

      def description
        "execute at most #{@max} queries"
      end

      def failure_message
        "expected to #{description}; #{result.summary}"
      end

      def failure_message_when_negated
        "expected not to #{description}; #{result.summary}"
      end
    end

    class QueryGrowthMatcher
      attr_reader :result

      def initialize(max_growth)
        QueryCapture.validate_limit!(max_growth)
        @max_growth = max_growth
      end

      def matches?(workloads)
        @result = QueryGrowth.new(**workloads, max_growth: @max_growth)
        result.within_limit?
      end

      def description
        "increase executed query count by at most #{@max_growth}"
      end

      def failure_message
        "expected to #{description}; #{result.summary}"
      end

      def failure_message_when_negated
        "expected not to #{description}; #{result.summary}"
      end
    end
  end
end
