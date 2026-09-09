# frozen_string_literal: true

module AndOne
  class Suggestion
    attr_reader :target_model, :origin_frame, :association_name, :parent_model,
                :fix_hint, :loading_strategy, :is_through, :is_polymorphic,
                :association_type, :operation

    def initialize(target_model:, origin_frame:, association_name:, parent_model:,
                   fix_hint:, loading_strategy: nil, **evidence)
      @target_model = target_model
      @origin_frame = origin_frame
      @association_name = association_name
      @parent_model = parent_model
      @fix_hint = fix_hint
      @loading_strategy = loading_strategy
      @is_through = evidence.fetch(:is_through, false)
      @is_polymorphic = evidence.fetch(:is_polymorphic, false)
      reflection = parent_model&.reflect_on_association(association_name) if association_name
      @association_type = evidence[:association_type] || reflection&.macro
      @operation = evidence.fetch(:operation, :records)
    end

    def actionable?
      !!@association_name && @operation == :records
    end

    def strict_loading_hint
      return nil unless actionable? && @parent_model && @association_type

      declaration = "#{@association_type} :#{@association_name}"
      declaration += ", through: ..." if @is_through
      "Or prevent lazy record loading: `#{declaration}, strict_loading: true` in #{@parent_model.name}"
    end

    def loading_strategy_hint
      return nil unless actionable?

      case @loading_strategy
      when :eager_load
        "Consider `.eager_load(:#{@association_name})` only if JOIN semantics are needed; verify results and query cost"
      when :preload
        "Consider `.preload(:#{@association_name})` for separate-query record loading; verify scopes and results"
      end
    end
  end
end
