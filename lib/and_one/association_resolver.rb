# frozen_string_literal: true

require_relative "query_evidence"
require_relative "suggestion"

module AndOne
  # SQL provides candidates, not proof of which Ruby association was called.
  module AssociationResolver
    module_function

    def resolve(detection, cleaned_backtrace)
      evidence = QueryEvidence.new(detection.sample_query, adapter: detection.adapter)
      target = model_for_table(detection.table_name)
      return nil unless target

      candidates = evidence.operation == :records ? association_candidates(target, evidence) : []
      parent, association = candidates.first if candidates.one?
      Suggestion.new(
        target_model: target, origin_frame: cleaned_backtrace&.first,
        parent_model: parent, association_name: association&.name,
        association_type: association&.macro, operation: evidence.operation,
        loading_strategy: association && evidence.operation == :records ? :includes : nil,
        fix_hint: recommendation(evidence.operation, parent, association)
      )
    end

    # Deliberately uncached: misses must not survive lazy loading and classes or
    # reflections must not survive a Rails reload. Ignore stale descendant objects
    # whose constants have been removed/replaced by the reloader.
    def models
      ActiveRecord::Base.descendants.select do |klass|
        klass.name && !klass.abstract_class? && klass.name.safe_constantize.equal?(klass)
      end
    end

    def model_for_table(table_name)
      return nil unless table_name

      matches = models.select { |klass| klass.table_name == table_name }
      matches.first if matches.one?
    end

    def association_candidates(target, evidence)
      return [] unless evidence.simple?

      models.flat_map do |parent|
        parent.reflect_on_all_associations.filter_map do |association|
          [parent, association] if association_matches?(association, target, evidence)
        end
      end
    end

    def association_matches?(association, target, evidence)
      return false unless %i[belongs_to has_one has_many].include?(association.macro)
      return false if association.is_a?(ActiveRecord::Reflection::ThroughReflection)
      return false if association.polymorphic? || association.options[:as]
      return false unless association.klass == target

      key = if association.macro == :belongs_to
              association.association_primary_key
            else
              association.foreign_key
            end
      return false if key.is_a?(Array)

      evidence.predicate_columns(target.table_name).include?(key.to_s)
    rescue NameError
      false
    end

    def recommendation(operation, parent, association)
      case operation
      when :count
        "For COUNT, consider a counter cache or grouped counts; use .size only on an already loaded association " \
        "when loading all records is acceptable. includes alone does not eliminate .count queries."
      when :exists
        "For existence checks, consider batching matching keys; verify equivalent scope and NULL semantics."
      when :scalar
        "For scalar lookups, consider a grouped/batched query; SQL alone cannot identify an association fix."
      when :records
        if association
          "If this is #{parent.name}##{association.name} record loading, try `.includes(:#{association.name})` " \
            "or `.preload(:#{association.name})` on the parent query; verify scopes and results."
        else
          "Association is ambiguous or unsupported from SQL alone; inspect the call site before choosing a preload."
        end
      else
        "Cannot infer a safe association fix from this SQL; inspect the call site."
      end
    end
  end
end
