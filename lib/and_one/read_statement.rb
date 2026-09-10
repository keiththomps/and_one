# frozen_string_literal: true

require_relative "sql_lexer"

module AndOne
  # Deliberately conservative lexical eligibility, not a general SQL parser.
  class ReadStatement
    WRITE_WORDS = %w[insert update delete merge replace create alter drop into].freeze

    def self.eligible?(sql, adapter: nil)
      tokens = SqlLexer.new(sql, adapter: adapter).tokens
      tokens.pop if tokens.last&.text == ";"
      return false if tokens.any? { |t| t.kind == :opaque || t.text == ";" }
      return false if tokens.any? { |t| t.kind == :word && WRITE_WORDS.include?(t.text) }

      new(tokens).read?
    end

    def initialize(tokens)
      @tokens = tokens.dup
    end

    def read?
      return true if take_word?("select")
      return false unless take_word?("with")

      take_word?("recursive")
      loop do
        return false unless %i[word identifier].include?(@tokens.shift&.kind)
        return false if @tokens.first&.text == "(" && !parenthesized
        return false unless take_word?("as")

        take_word?("not")
        take_word?("materialized")
        body = parenthesized
        return false unless body && self.class.new(body).read?
        break unless @tokens.first&.text == ","

        @tokens.shift
      end
      take_word?("select")
    end

    private

    def take_word?(word)
      return false unless @tokens.first&.kind == :word && @tokens.first.text == word

      @tokens.shift
      true
    end

    def parenthesized
      return unless @tokens.shift&.text == "("

      depth = 1
      body = []
      until @tokens.empty?
        token = @tokens.shift
        depth += 1 if token.text == "("
        depth -= 1 if token.text == ")"
        return body if depth.zero?

        body << token
      end
      nil
    end
  end
end
