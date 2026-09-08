# frozen_string_literal: true

require_relative "sql_lexer"

module AndOne
  # Version 2 normalizes tokens instead of applying substitutions to raw SQL.
  # Quoted identifiers and structural clauses are deliberately preserved.
  module Fingerprint
    NORMALIZATION_VERSION = 2

    module_function

    def generate(sql, adapter: nil)
      tokens = SqlLexer.new(sql, adapter: adapter).tokens
      normalized = []
      index = 0
      while index < tokens.size
        token = tokens[index]
        normalized << token.text
        closing = token.kind == :word && token.text == "in" ? parameter_list_end(tokens, index + 1) : nil
        if closing
          normalized.push("(", "?", ")")
          index = closing + 1
        else
          index += 1
        end
      end
      normalized.join(" ")
    end

    def parameter_list_end(tokens, index)
      return unless tokens[index]&.text == "("

      index += 1
      loop do
        return unless tokens[index]&.kind == :parameter

        index += 1
        return index if tokens[index]&.text == ")"
        return unless tokens[index]&.text == ","

        index += 1
      end
    end
    private_class_method :parameter_list_end
  end
end
