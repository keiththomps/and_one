# frozen_string_literal: true

module AndOne
  # Parses and matches against a `.and_one_ignore` file.
  #
  # The file supports four types of rules:
  #
  #   # Lines starting with # are comments
  #
  #   # Ignore N+1s originating from a specific gem
  #   gem:devise
  #   gem:administrate
  #
  #   # Ignore N+1s whose call stack matches a path pattern (supports * globs)
  #   path:app/views/admin/*
  #   path:lib/legacy/**
  #
  #   # Ignore N+1s matching a SQL pattern
  #   query:schema_migrations
  #   query:pg_catalog
  #
  #   # Ignore a specific detection by its fingerprint (shown in output)
  #   fingerprint:abc123def456
  #
  class IgnoreFile
    Rule = Struct.new(:type, :pattern, keyword_init: true)

    attr_reader :rules

    def initialize(path = nil)
      @path = path
      @rules = []
      parse if @path && File.exist?(@path)
    end

    # Check if a detection should be ignored.
    # raw_caller_strings: the UN-cleaned caller locations (full paths, including gems)
    # detection: the Detection object
    def ignored?(detection, raw_caller_strings)
      return false if @rules.empty?

      @rules.any? { |rule| matches?(rule, detection, raw_caller_strings) }
    end

    private

    def parse
      File.readlines(@path).each do |line|
        line = line.strip

        # Skip blanks and comments
        next if line.empty? || line.start_with?("#")

        type, pattern = line.split(":", 2)
        next unless type && pattern && !pattern.empty?

        type = type.strip.downcase.to_sym
        pattern = pattern.strip

        next unless %i[gem path query fingerprint].include?(type)

        @rules << Rule.new(type: type, pattern: pattern)
      end
    end

    def matches?(rule, detection, raw_caller_strings)
      case rule.type
      when :gem
        matches_gem?(rule.pattern, raw_caller_strings)
      when :path
        matches_path?(rule.pattern, raw_caller_strings)
      when :query
        matches_query?(rule.pattern, detection)
      when :fingerprint
        matches_fingerprint?(rule.pattern, detection)
      else
        false
      end
    end

    # Match against gem paths in the raw (uncleaned) backtrace.
    # A gem rule "devise" matches any frame containing /gems/devise-
    def matches_gem?(gem_name, raw_caller_strings)
      gem_pattern = %r{/gems/#{Regexp.escape(gem_name)}-}
      raw_caller_strings.any? { |frame| frame.match?(gem_pattern) }
    end

    # Match against app paths using glob-style patterns.
    # "app/views/admin/*" matches "app/views/admin/index.html.erb:5"
    def matches_path?(glob, raw_caller_strings)
      # Convert glob to regex: * -> [^/]*, ** -> .*
      regex_str = Regexp.escape(glob)
                        .gsub('\*\*', '.*')
                        .gsub('\*', '[^/]*')
      regex = Regexp.new(regex_str)
      raw_caller_strings.any? { |frame| frame.match?(regex) }
    end

    # Match against the SQL query text
    def matches_query?(pattern, detection)
      detection.queries.any? { |q| q.include?(pattern) }
    end

    # Match against the detection's stable fingerprint
    def matches_fingerprint?(fp, detection)
      detection.fingerprint == fp
    end
  end
end
