# frozen_string_literal: true

module AndOne
  # SQL fingerprinting without external dependencies.
  # Normalizes queries so that the same query shape with different bind values
  # produces the same fingerprint. Works with PostgreSQL, MySQL, and SQLite.
  module Fingerprint
    module_function

    def generate(sql)
      normalized = sql.dup

      # Remove SQL comments
      normalized.gsub!(%r{/\*[^!].*?\*/}m, "")
      normalized.gsub!(/(?:--|#)[^\r\n]*(?=[\r\n]|\z)/, "")

      # Replace double-quoted identifiers with unquoted versions (PostgreSQL/SQLite style)
      # "posts" -> posts, "posts"."id" -> posts.id
      normalized.gsub!(/"(\w+)"/, '\1')

      # Replace backtick-quoted identifiers (MySQL style)
      normalized.gsub!(/`(\w+)`/, '\1')

      # Normalize single-quoted string literals
      normalized.gsub!("\\'", "")
      normalized.gsub!(/'(?:[^'\\]|\\.)*'/m, "?")

      # Normalize numbers (standalone, not part of identifiers)
      normalized.gsub!(/\b\d+(?:\.\d+)?\b/, "?")

      # Normalize booleans and NULL
      normalized.gsub!(/\b(?:true|false)\b/i, "?")
      normalized.gsub!(/\bNULL\b/i, "?")

      # Normalize IN lists: IN (?, ?, ?) -> IN (?)
      normalized.gsub!(/\bIN\s*\(\s*\?(?:\s*,\s*\?)*\s*\)/i, "IN (?)")

      # Normalize VALUES lists
      normalized.gsub!(/\bVALUES\s*\([\s?,]*\)(?:\s*,\s*\([\s?,]*\))*/i, "VALUES (?)")

      # Normalize whitespace
      normalized.gsub!(/\s+/, " ")
      normalized.strip!
      normalized.downcase!

      # Normalize LIMIT/OFFSET
      normalized.gsub!(/\blimit \?(?:, ?\?| offset \?)?/, "limit ?")

      # Normalize $1, $2, ... placeholders (PostgreSQL)
      normalized.gsub!(/\$\d+/, "?")

      normalized
    end
  end
end
