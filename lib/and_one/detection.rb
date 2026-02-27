# frozen_string_literal: true

module AndOne
  # Represents a single N+1 detection: the repeated queries, their call site, and metadata.
  class Detection
    attr_reader :queries, :caller_locations, :count, :adapter

    def initialize(queries:, caller_locations:, count:, adapter: nil)
      @queries = queries
      @caller_locations = caller_locations
      @count = count
      @adapter = adapter
    end

    # Returns the SQL of the first query as the representative example
    def sample_query
      @queries.first
    end

    # Attempt to extract the table name from the repeated query
    def table_name
      @table_name ||= extract_table_name(sample_query)
    end

    private

    def extract_table_name(sql)
      # Handle: SELECT "posts".* FROM "posts" WHERE ...
      # Handle: SELECT `posts`.* FROM `posts` WHERE ...
      # Handle: SELECT posts.* FROM posts WHERE ...
      if sql =~ /\bFROM\s+["`]?(\w+)["`]?/i
        $1
      end
    end
  end
end
