# frozen_string_literal: true

require "test_helper"

class TestAssociationResolver < Minitest::Test
  include AndOneTestHelper

  def setup
    super
    seed_data!
  end

  def teardown
    super
    Comment.delete_all
    Post.delete_all
    Author.delete_all
  end

  def test_suggestion_has_strict_loading_hint
    detections = AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    suggestion = AndOne::AssociationResolver.resolve(detections.first, detections.first.raw_caller_strings)

    assert suggestion.actionable?
    refute_nil suggestion.strict_loading_hint
    assert_includes suggestion.strict_loading_hint, "strict_loading: true"
    assert_includes suggestion.strict_loading_hint, "Post"
  end

  def test_suggestion_includes_loading_strategy
    detections = AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end

    suggestion = AndOne::AssociationResolver.resolve(detections.first, detections.first.raw_caller_strings)

    assert suggestion.actionable?
    # Default strategy should be :includes (no extra hint for simple case)
    assert_equal :includes, suggestion.loading_strategy
    assert_nil suggestion.loading_strategy_hint
  end

  def test_non_actionable_suggestion_has_no_hints
    suggestion = AndOne::Suggestion.new(
      target_model: Post,
      origin_frame: nil,
      association_name: nil,
      parent_model: nil,
      fix_hint: nil
    )

    refute suggestion.actionable?
    assert_nil suggestion.strict_loading_hint
    assert_nil suggestion.loading_strategy_hint
  end

  def test_eager_load_strategy_hint
    suggestion = AndOne::Suggestion.new(
      target_model: Comment,
      origin_frame: "test:1",
      association_name: :comments,
      parent_model: Post,
      fix_hint: "Add .includes(:comments)",
      loading_strategy: :eager_load
    )

    assert_includes suggestion.loading_strategy_hint, "eager_load"
    assert_includes suggestion.loading_strategy_hint, "JOIN"
  end
end
