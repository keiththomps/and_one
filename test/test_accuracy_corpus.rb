# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/accuracy_corpus"

class TestAccuracyCorpus < Minitest::Test
  include AndOneTestHelper

  def setup
    super
    AccuracyCorpus.setup!
    seed_data!
  end

  def teardown
    Comment.delete_all
    Post.delete_all
    Author.delete_all
    AccuracyCorpus.teardown!
    super
  end

  AccuracyCorpus.scenarios.each do |scenario|
    define_method("test_corpus_#{scenario.fetch(:name)}") do
      diagnostic = "#{scenario[:name]}: truth=#{scenario[:truth]}, observed=#{scenario[:observed]}; #{scenario[:limitation]}"
      workload = scenario[:workload] || -> { AccuracyCorpus.records(scenario[:model].call.all, scenario[:association]) }
      detections = nil
      baseline, before = measure do
        detections = AndOne.scan { @result = workload.call }
        @result
      end
      if scenario[:observed] == :none
        assert_empty detections, diagnostic
        assert_equal scenario[:physical], before, diagnostic
      else
        refute_empty detections, diagnostic
        assert_equal [scenario[:kind]], detections.map(&:kind).uniq, diagnostic if scenario[:kind]
        suggestions = detections.map { |detection| AndOne::AssociationResolver.resolve(detection, detection.raw_caller_strings) }
        refute_includes suggestions, nil, diagnostic
        assert_equal scenario[:observed] == :candidate, suggestions.all?(&:actionable?), diagnostic
        assert_equal [scenario[:operation]], suggestions.map(&:operation).uniq, diagnostic if scenario[:operation]
        verify_recommendation(scenario, suggestions, baseline, before, diagnostic) if scenario[:association] && scenario[:observed] == :candidate
      end
    end
  end

  def test_real_adapter_prepared_queries_capture_binds_and_preload_eliminates_repetition
    connection = ActiveRecord::Base.connection
    assert connection.prepared_statements, "#{connection.adapter_name} must exercise prepared queries"
    events = []
    subscriber = ->(*args) { events << args.last if args.last[:name] != "SCHEMA" }
    detections = nil
    ActiveRecord::Base.uncached do
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        detections = AndOne.scan { AccuracyCorpus.records(CorpusOwner.all, :items) }
      end
    end
    child_events = events.select { |payload| payload[:sql].include?("corpus_items") }
    assert_equal 3, child_events.size
    assert child_events.all? { |payload| !payload[:binds].empty? }, "expected real #{connection.adapter_name} bind metadata"
    assert_equal 1, detections.size
    assert_equal 3, detections.first.count
    assert_equal :suspected_association_n_plus_one, detections.first.kind
    assert_equal ActiveRecord::Base.connection_db_config.adapter, detections.first.adapter
    assert_empty(AndOne.scan { AccuracyCorpus.records(CorpusOwner.preload(:items), :items) })
  end

  def test_empty_prepared_results_remain_readable_and_are_measured
    connection = ActiveRecord::Base.connection
    assert connection.prepared_statements, "#{connection.adapter_name} must exercise prepared queries"
    # mysql2 0.5.7 frees empty prepared-result metadata before Rails reads fields.
    # Do not skip empty results or disable prepared statements to hide that crash.
    events = []
    subscriber = ->(*args) { events << args.last unless args.last[:name] == "SCHEMA" }
    results = []
    detections = nil
    ActiveRecord::Base.uncached do
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        detections = AndOne.scan do
          3.times { results << CorpusItem.where(owner_code: "missing-owner").pluck(:id) }
        end
      end
    end

    assert_equal [[], [], []], results
    assert_equal 3, events.size
    assert events.all? { |payload| !payload[:binds].empty? }, "expected bound empty-result queries"
    assert_equal 1, detections.size
    assert_equal 3, detections.first.count
    assert_equal 3, detections.first.query_cost.timed_query_count
  end

  private

  def verify_recommendation(scenario, suggestions, baseline, before, diagnostic)
    association = scenario.fetch(:association)
    assert_equal [association], suggestions.map(&:association_name).uniq, diagnostic
    %i[includes preload].each do |strategy|
      assert_includes suggestions.first.fix_hint, ".#{strategy}(:#{association})", diagnostic
      detections = nil
      fixed, after = measure do
        detections = AndOne.scan do
          @result = AccuracyCorpus.records(scenario[:model].call.public_send(strategy, association), association)
        end
        @result
      end
      assert_equal baseline, fixed, "#{diagnostic}; #{strategy} changed results"
      assert_operator after, :<, before, "#{diagnostic}; #{strategy} did not reduce physical queries"
      assert_equal 2, after, diagnostic
      assert_empty detections, diagnostic
    end
  end

  def measure(&block)
    count = 0
    subscriber = lambda do |*args|
      payload = args.last
      count += 1 unless payload[:cached] || %w[SCHEMA TRANSACTION].include?(payload[:name])
    end
    result = ActiveRecord::Base.uncached do
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record", &block)
    end
    [result, count]
  end
end
