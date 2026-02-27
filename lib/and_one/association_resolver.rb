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
        fix_hint: suggestion&.dig(:fix_hint)
      )
    end

    # Maps table name -> AR model class
    def model_for_table(table_name)
      # Use AR's descendants to find the model for this table
      @table_model_cache ||= {}
      return @table_model_cache[table_name] if @table_model_cache.key?(table_name)

      model = ActiveRecord::Base.descendants.detect do |klass|
        klass.table_name == table_name
      rescue
        false
      end

      @table_model_cache[table_name] = model
      model
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
      return nil unless foreign_key

      # Search all models for an association whose foreign key matches
      ActiveRecord::Base.descendants.each do |klass|
        next if klass.abstract_class?

        klass.reflect_on_all_associations.each do |assoc|
          next unless association_matches?(assoc, target_model, foreign_key)

          return {
            parent_model: klass,
            association_name: assoc.name,
            fix_hint: build_fix_hint(klass, assoc.name)
          }
        end
      rescue
        next
      end

      nil
    end

    def extract_foreign_key(sql, table_name)
      # Match patterns like: "table"."column_id" = or "table"."column_id" IN
      pattern = /["`]?#{Regexp.escape(table_name)}["`]?\.["`]?(\w+_id)["`]?\s*(?:=|IN)/i
      match = sql.match(pattern)
      match&.captures&.first
    end

    def association_matches?(assoc, target_model, foreign_key)
      return false unless assoc.is_a?(ActiveRecord::Reflection::HasManyReflection) ||
                          assoc.is_a?(ActiveRecord::Reflection::HasOneReflection)

      begin
        assoc.klass == target_model && assoc.foreign_key.to_s == foreign_key
      rescue NameError
        false
      end
    end

    def build_fix_hint(parent_model, association_name)
      "Add `.includes(:#{association_name})` to your #{parent_model.name} query"
    end
  end

  class Suggestion
    attr_reader :target_model, :origin_frame, :association_name, :parent_model, :fix_hint

    def initialize(target_model:, origin_frame:, association_name:, parent_model:, fix_hint:)
      @target_model = target_model
      @origin_frame = origin_frame
      @association_name = association_name
      @parent_model = parent_model
      @fix_hint = fix_hint
    end

    def actionable?
      !!@association_name
    end
  end
end
