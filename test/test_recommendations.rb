# frozen_string_literal: true

require "test_helper"

class TestRecommendations < Minitest::Test
  include AndOneTestHelper

  def setup
    super
    seed_data!
  end

  def teardown
    Comment.delete_all
    Post.delete_all
    Author.delete_all
    super
  end

  def test_record_loading_advice_reduces_queries_with_equivalent_results
    %i[includes preload].each do |strategy|
      suggestion = resolve(scan { Post.all.each { |post| post.comments.to_a } })
      assert_equal :comments, suggestion.association_name
      assert_includes suggestion.fix_hint, ".#{strategy}(:comments)"
      baseline, before = measure { Post.all.map { |post| post.comments.map(&:id) } }
      fixed, after = measure { Post.public_send(strategy, :comments).map { |post| post.comments.map(&:id) } }
      assert_equal baseline, fixed
      assert_operator after, :<, before
      assert_equal 2, after
    end
  end

  def test_belongs_to_and_has_many_advice_preserve_results
    %i[includes preload].each do |strategy|
      suggestion = resolve(scan { Post.all.each(&:author) })
      assert_equal :author, suggestion.association_name
      assert_includes suggestion.fix_hint, ".#{strategy}(:author)"
      baseline, before = measure { Post.all.map { |post| post.author.name } }
      fixed, after = measure { Post.public_send(strategy, :author).map { |post| post.author.name } }
      assert_equal baseline, fixed
      assert_operator after, :<, before
      assert_equal 2, after
    end
  end

  def test_count_advice_is_not_an_includes_fix
    detection = scan { Post.all.each { |post| post.comments.count } }
    suggestion = resolve(detection)
    assert_equal :count, suggestion.operation
    refute suggestion.actionable?
    assert_nil suggestion.loading_strategy
    assert_nil suggestion.strict_loading_hint
    assert_includes suggestion.fix_hint, "counter cache"
    assert_includes suggestion.fix_hint, "includes alone does not eliminate .count"

    counts, before = measure { Post.all.map { |post| post.comments.count } }
    loaded_counts, after = measure { Post.preload(:comments).map { |post| post.comments.size } }
    assert_equal counts, loaded_counts
    assert_operator after, :<, before
  end

  def test_exists_and_scalar_queries_do_not_invent_association_fixes
    exists = resolve(scan { Post.all.each { |post| post.comments.exists? } })
    scalar = resolve(scan { Post.all.each { |post| post.comments.pluck(:body) } })
    assert_equal :exists, exists.operation
    assert_equal :scalar, scalar.operation
    [exists, scalar].each do |suggestion|
      refute suggestion.actionable?
      assert_nil suggestion.association_name
      assert_nil suggestion.loading_strategy
      refute_includes suggestion.fix_hint, ".includes"
    end
  end

  def test_and_or_and_join_do_not_imply_join_efficiency
    ["AND comments.body = 'hello'", "OR comments.body = 'hello'"].each do |condition|
      detection = detection_for("SELECT comments.* FROM comments WHERE comments.post_id = 1 #{condition}")
      suggestion = resolve(detection)
      refute_equal :eager_load, suggestion.loading_strategy
      refute_includes suggestion.fix_hint, "more efficient"
    end
    suggestion = resolve(detection_for("SELECT comments.* FROM comments JOIN posts ON posts.id = comments.post_id"))
    refute suggestion.actionable?
  end

  def test_lexer_ignores_keywords_in_literals_and_comments
    suggestion = resolve(detection_for("SELECT comments.* FROM comments WHERE comments.post_id = 1 AND comments.body = 'COUNT EXISTS JOIN' /* OR */"))
    assert_equal :records, suggestion.operation
    assert_equal :comments, suggestion.association_name
    assert_equal :includes, suggestion.loading_strategy
  end

  def test_all_outputs_qualify_locations_and_show_count_guidance
    detection = detection_for("SELECT COUNT(*) FROM comments WHERE comments.post_id = 1")
    text = AndOne::Formatter.new.format([detection])
    assert_includes text, "Possible fix location (heuristic"
    assert_includes text, "counter cache"
    refute_includes text, "Fix here"

    json = AndOne::JsonFormatter.new.format_hashes([detection]).first
    assert_equal "heuristic", json[:fix_location_confidence]
    assert_equal "count", json[:suggestion][:operation]
    assert_equal "guidance_only", json[:suggestion][:confidence]

    AndOne.aggregate.record(detection)
    _, _, body = AndOne::DevUI.new(nil).call("PATH_INFO" => "/__and_one")
    assert_includes body.join, "Possible fix location (heuristic)"
    assert_includes body.join, "counter cache"

    output, = capture_io { AndOne.send(:report_annotations, [detection]) }
    assert_includes output, "Possible fix location (heuristic)"
    assert_includes output, "counter cache"
    refute_includes output, "to fix."
  end

  private

  def scan(&)
    detections = AndOne.scan(&)
    refute_empty detections
    detections.first
  end

  def resolve(detection)
    AndOne::AssociationResolver.resolve(detection, detection.raw_caller_strings)
  end

  def detection_for(sql)
    AndOne::Detection.new(queries: [sql], count: 3, adapter: "SQLite",
                          raw_caller_strings: ["app/models/post.rb:10:in 'comments'", "app/controllers/posts_controller.rb:20:in 'index'"])
  end

  def measure(&block)
    count = 0
    subscriber = lambda do |*args|
      payload = args.last
      count += 1 unless payload[:cached] || payload[:name] == "SCHEMA"
    end
    result = ActiveRecord::Base.uncached do
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record", &block)
    end
    [result, count]
  end
end
