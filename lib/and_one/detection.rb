# frozen_string_literal: true

require "digest"
require "json"
require_relative "query_cost"

module AndOne
  # Represents a single N+1 detection: the repeated queries, their call site, and metadata.
  class Detection
    # queries contains representative samples; count is the exact occurrence total.
    attr_reader :queries, :caller_locations, :count, :adapter, :connection_id, :query_cost

    # Keep the legacy keyword construction API while adding optional measurements.
    # rubocop:disable Metrics/ParameterLists
    def initialize(queries:, count:, caller_locations: nil, raw_caller_strings: nil, adapter: nil,
                   connection_id: nil, issue_id: nil, fingerprint: nil, query_cost: nil)
      @query_cost = query_cost
      @queries = queries
      @caller_locations = caller_locations
      @raw_caller_strings_override = raw_caller_strings
      @count = count
      @adapter = adapter
      @connection_id = connection_id
      @issue_id = issue_id
      @fingerprint = fingerprint
    end
    # rubocop:enable Metrics/ParameterLists

    # Returns the SQL of the first query as the representative example
    def sample_query
      @queries.first
    end

    # Attempt to extract the table name from the repeated query
    def table_name
      @table_name ||= extract_table_name(sample_query)
    end

    # A stable fingerprint for this detection, based on the query shape and
    # the target table. Independent of call site so the same N+1 pattern
    # produces the same fingerprint regardless of where it's triggered.
    # For location-specific ignoring, use `path:` rules in .and_one_ignore.
    def fingerprint
      @fingerprint ||= begin
        sql_fp = Fingerprint.generate(sample_query, adapter: adapter)
        Digest::SHA256.hexdigest("#{sql_fp}:#{table_name}")[0, 12]
      end
    end

    # Unlike fingerprint (the public broad ignore key), this identifies a
    # query shape at one application call site on one configured connection.
    def issue_id
      @issue_id ||= Digest::SHA256.hexdigest([fingerprint, normalized_origin, adapter, connection_id].to_json)[0, 24]
    end

    def normalized_origin
      frame = origin_frame
      return nil unless frame

      path, line = frame.split(/:(\d+)/, 3)
      root = defined?(Rails) && Rails.respond_to?(:root) && Rails.root ? Rails.root.to_s : Dir.pwd
      path = path.delete_prefix("#{root}/")
      path = path.sub(%r{\A/.*?/(app|lib|test|spec)/}, '\\1/')
      # Outside the application root, only retain a portable filename.
      path = File.basename(path) if path.start_with?("/")
      [path, line].compact.join(":")
    end

    # The raw caller strings (before backtrace cleaning)
    def raw_caller_strings
      @raw_caller_strings ||= @raw_caller_strings_override || caller_locations&.map(&:to_s) || []
    end

    # The first frame in the call stack that is application code
    # (not a gem, not ruby stdlib, not and_one itself)
    def origin_frame
      @origin_frame ||= find_origin_frame
    end

    # The frame where the AR relation/collection was likely loaded or iterated.
    # Heuristic only: the stack does not identify where a relation was built.
    def fix_location
      @fix_location ||= find_fix_location
    end

    private

    def extract_table_name(sql)
      return unless sql =~ /\bFROM\s+["`]?(\w+)["`]?/i

      ::Regexp.last_match(1)
    end

    def find_origin_frame
      raw_caller_strings.detect { |frame| app_frame?(frame) }
    end

    # Walk the backtrace looking for the frame that set up the iteration.
    # In a typical N+1, the stack looks like:
    #   - AR internals (loading the association)
    #   - The line calling .to_a / accessing the association (origin_frame)
    #   - The .each / .map / .find_each iteration
    #   - The controller/view/job that built the relation
    #
    # We want the outermost app frame that's near an AR relation method,
    # or failing that, the second app frame (the caller OF the origin).
    def find_fix_location
      app_frames = raw_caller_strings.select { |f| app_frame?(f) }
      return nil if app_frames.empty?

      # The first app frame is where the association is accessed (inside the loop).
      # The second app frame is often where the loop itself is, or the controller action.
      # If they're on the same file+line, look further up.
      if app_frames.size >= 2 && app_frames[0] != app_frames[1]
        app_frames[1]
      else
        app_frames.detect { |f| f != app_frames[0] } || app_frames.first
      end
    end

    def app_frame?(frame)
      # Not a gem
      !frame.include?("/gems/") &&
        # Not ruby stdlib / core
        !frame.include?("/ruby/") &&
        # Not and_one's own lib code
        !frame.include?("lib/and_one/") &&
        # Not <internal: or (eval) type frames
        !frame.start_with?("<internal:") &&
        !frame.include?("(eval)")
    end
  end
end
