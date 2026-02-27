# frozen_string_literal: true

module AndOne
  # Resolves table names back to ActiveRecord models and identifies
  # which association is being N+1 loaded, then suggests a fix.
  module AssociationResolver
    module_function

    # Given a table name and a cleaned backtrace, attempt to identify
    # the model, the parent association, and suggest an includes() fix.
    def resolve(detection, cleaned_backtrace)
      table = detection.table_name
      return nil unless table

      target_model = model_for_table(table)
      return nil unless target_model

      # Find the originating code location (first app frame in the backtrace)
      origin_frame = find_origin_frame(cleaned_backtrace)

      # Look for the parent model that has an association to the target
      suggestion = find_association_suggestion(target_model, detection.sample_query)

      Suggestion.new(
        target_model: target_model,
        origin_frame: origin_frame,
        association_name: suggestion&.dig(:association_name),
        parent_model: suggestion&.dig(:parent_model),
        fix_hint: suggestion&.dig(:fix_hint),
        loading_strategy: suggestion&.dig(:loading_strategy),
        is_through: suggestion&.dig(:is_through) || false,
        is_polymorphic: suggestion&.dig(:is_polymorphic) || false
      )
    end

    # Maps table name -> AR model class.
    # Thread-safe: uses a Mutex to protect the shared cache since multiple
    # Puma threads may resolve associations concurrently.
    def model_for_table(table_name)
      @table_model_mutex ||= Mutex.new
      @table_model_cache ||= {}

      # Fast path: read from cache without lock (safe because we never delete keys,
      # and Hash#[] under GVL is atomic for existing keys)
      return @table_model_cache[table_name] if @table_model_cache.key?(table_name)

      @table_model_mutex.synchronize do
        # Double-check after acquiring lock
        return @table_model_cache[table_name] if @table_model_cache.key?(table_name)

        model = ActiveRecord::Base.descendants.detect do |klass|
          klass.table_name == table_name
        rescue StandardError
          false
        end

        @table_model_cache[table_name] = model
        model
      end
    end

    # Finds the first backtrace frame that's in the app (not a gem/framework frame)
    def find_origin_frame(cleaned_backtrace)
      cleaned_backtrace&.first
    end

    # Tries to find which association on a parent model points to the target model,
    # and extracts hints from the WHERE clause about the foreign key.
    def find_association_suggestion(target_model, sql)
      # Extract the foreign key column from WHERE clause
      # e.g., WHERE "comments"."post_id" = ? or WHERE "comments"."post_id" IN (?)
      foreign_key = extract_foreign_key(sql, target_model.table_name)

      # Also try polymorphic foreign key pattern (e.g., commentable_id)
      poly_foreign_key = extract_polymorphic_foreign_key(sql, target_model.table_name) unless foreign_key

      effective_key = foreign_key || poly_foreign_key

      # Search all models for an association whose foreign key matches
      ActiveRecord::Base.descendants.each do |klass|
        next if klass.abstract_class?

        klass.reflect_on_all_associations.each do |assoc|
          matched = if effective_key
                      association_matches?(assoc, target_model, effective_key)
                    else
                      # For through associations, foreign key may not be directly visible
                      through_association_matches?(assoc, target_model)
                    end

          next unless matched

          strategy = loading_strategy(sql, assoc.name)

          return {
            parent_model: klass,
            association_name: assoc.name,
            fix_hint: build_fix_hint(klass, assoc.name),
            loading_strategy: strategy,
            is_through: assoc.is_a?(ActiveRecord::Reflection::ThroughReflection),
            is_polymorphic: assoc.respond_to?(:options) && !assoc.options[:as].nil?
          }
        end
      rescue StandardError
        next
      end

      nil
    end

    def through_association_matches?(assoc, target_model)
      return false unless assoc.is_a?(ActiveRecord::Reflection::ThroughReflection)

      begin
        assoc.klass == target_model
      rescue NameError
        false
      end
    end

    def extract_polymorphic_foreign_key(sql, table_name)
      # Match patterns like: "table"."something_type" = AND "table"."something_id"
      pattern = /["`]?#{Regexp.escape(table_name)}["`]?\.["`]?(\w+)_type["`]?\s*=/i
      match = sql.match(pattern)
      "#{match.captures.first}_id" if match
    end

    def extract_foreign_key(sql, table_name)
      # Match patterns like: "table"."column_id" = or "table"."column_id" IN
      pattern = /["`]?#{Regexp.escape(table_name)}["`]?\.["`]?(\w+_id)["`]?\s*(?:=|IN)/i
      match = sql.match(pattern)
      match&.captures&.first
    end

    def association_matches?(assoc, target_model, foreign_key)
      case assoc
      when ActiveRecord::Reflection::ThroughReflection
        # has_many :through — check if the source association points to our target
        assoc.klass == target_model
      when ActiveRecord::Reflection::HasManyReflection,
           ActiveRecord::Reflection::HasOneReflection
        if assoc.options[:as]
          # Polymorphic: has_many :comments, as: :commentable
          # The foreign key is like "commentable_id" and there's a "commentable_type" column
          poly_fk = "#{assoc.options[:as]}_id"
          assoc.klass == target_model && poly_fk == foreign_key
        else
          assoc.klass == target_model && assoc.foreign_key.to_s == foreign_key
        end
      else
        false
      end
    rescue NameError
      false
    end

    def build_fix_hint(parent_model, association_name)
      "Add `.includes(:#{association_name})` to your #{parent_model.name} query"
    end

    # Determine the optimal loading strategy based on query patterns
    def loading_strategy(sql, _association_name)
      # If the query has WHERE conditions on the association table, eager_load
      # is better because it does a LEFT OUTER JOIN allowing WHERE filtering
      if sql =~ /\bWHERE\b/i && (sql =~ /\bJOIN\b/i || sql =~ /\b(?:AND|OR)\b/i)
        :eager_load
      else
        # Default: preload is generally faster (separate queries, no JOIN overhead)
        # includes is the safe default that lets Rails choose
        :includes
      end
    end
  end

  class Suggestion
    attr_reader :target_model, :origin_frame, :association_name, :parent_model,
                :fix_hint, :loading_strategy, :is_through, :is_polymorphic

    def initialize(target_model:, origin_frame:, association_name:, parent_model:,
                   fix_hint:, loading_strategy: nil, is_through: false, is_polymorphic: false)
      @target_model = target_model
      @origin_frame = origin_frame
      @association_name = association_name
      @parent_model = parent_model
      @fix_hint = fix_hint
      @loading_strategy = loading_strategy
      @is_through = is_through
      @is_polymorphic = is_polymorphic
    end

    def actionable?
      !!@association_name
    end

    # Suggest strict_loading as an alternative prevention strategy
    def strict_loading_hint
      return nil unless actionable? && @parent_model

      assoc_type = if @is_through
                     "has_many :#{@association_name}, through: ..."
                   else
                     "has_many :#{@association_name}"
                   end

      "Or prevent at the model level: `#{assoc_type}, strict_loading: true` in #{@parent_model.name}"
    end

    # Suggest the optimal loading strategy when it differs from plain .includes
    def loading_strategy_hint
      return nil unless actionable? && @loading_strategy

      case @loading_strategy
      when :eager_load
        "Consider `.eager_load(:#{@association_name})` instead — your query filters on the association, so a JOIN is more efficient"
      when :preload
        "Consider `.preload(:#{@association_name})` — separate queries avoid JOIN overhead for simple loading"
      end
    end
  end
end
