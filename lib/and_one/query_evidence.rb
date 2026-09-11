# frozen_string_literal: true

require_relative "sql_lexer"

module AndOne
  # Conservative evidence for advice, not a general SQL classifier. Only plain
  # single-table SELECTs with qualified equality/IN predicates support resolution.
  class QueryEvidence
    def initialize(sql, adapter: nil)
      @tokens = SqlLexer.new(sql, adapter: adapter).tokens
    end

    def operation
      return :unknown unless word?(@tokens.first, "select")

      projection = @tokens[1...from_index]
      return :count if word?(projection.first, "count") && projection[1]&.text == "("
      return :aggregate if projection.first&.kind == :word && %w[sum avg min max].include?(projection.first.text) && projection[1]&.text == "("
      return :exists if word?(projection.first, "exists") || existence_projection?(projection)
      return :records if projection.map(&:text) == ["*"] || record_projection?(projection)

      :scalar
    end

    def simple?
      from_index && word?(@tokens.first, "select") &&
        @tokens.none? { |token| token.kind == :opaque || (token.kind == :word && %w[join union intersect except or].include?(token.text)) } &&
        @tokens.one? { |token| word?(token, "select") } && single_table?
    end

    def predicate_columns(table)
      where = @tokens.index { |token| word?(token, "where") }
      return [] unless where

      @tokens[(where + 1)..].each_cons(4).filter_map do |owner, dot, column, operator|
        next unless identifier(owner) == table && dot.text == "."
        next unless operator.text == "=" || word?(operator, "in")

        identifier(column)
      end
    end

    private

    def from_index
      @from_index ||= @tokens.index { |token| word?(token, "from") }
    end

    def single_table?
      tail = @tokens[(from_index + 1)..]
      boundary = tail.index { |token| token.kind == :word && %w[where limit order group having offset].include?(token.text) }
      source = boundary ? tail.first(boundary) : tail
      source = source.reject { |token| token.text == ";" }
      source.one? && identifier(source.first)
    end

    def existence_projection?(projection)
      # Redacted literals become ?, which PostgreSQL lexes as a JSON operator.
      # Accept that display marker only in the exact `? AS one` projection.
      projection.size == 3 && %i[parameter symbol].include?(projection.first.kind) && projection.first.text == "?" &&
        word?(projection[1], "as") && identifier(projection[2]) == "one"
    end

    def record_projection?(projection)
      projection.size == 3 && identifier(projection[0]) && projection[1].text == "." && projection[2].text == "*"
    end

    def word?(token, text)
      token&.kind == :word && token.text == text
    end

    def identifier(token)
      return token.text if token&.kind == :word
      return unless token&.kind == :identifier

      token.text[1...-1]
    end
  end
end
