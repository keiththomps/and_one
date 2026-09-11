# frozen_string_literal: true

require_relative "test_helper"

class TestRepetitionEvidence < Minitest::Test
  include AndOneTestHelper

  SQL = 'SELECT "comments".* FROM "comments" WHERE "comments"."post_id" = ?'

  def capture(values, sql: SQL, **)
    detector = AndOne::Detector.new(**)
    values.each do |value|
      payload = { sql: sql, type_casted_binds: value, connection: ActiveRecord::Base.connection }
      detector.record(payload)
    end
    detector.finish.first
  end

  def test_prepared_values_distinguish_duplicates_and_candidates
    duplicate = capture([[1], [1]])
    varying = capture([[1], [2]])
    assert_equal :duplicate_identical_read, duplicate.kind
    assert_equal :observed, duplicate.confidence
    assert_equal :suspected_association_n_plus_one, varying.kind
    assert_equal :candidate, varying.confidence
    assert_equal duplicate.fingerprint, varying.fingerprint
    refute AndOne::AssociationResolver.resolve(duplicate, []).actionable?
  end

  def test_missing_lazy_unsupported_and_oversized_metadata_abstains
    lazy = -> { flunk "must not call lazy binds" }
    [nil, false, lazy, [Object.new], ["x" * 8193], Array.new(65, 1), [], [1, 2]].each do |binds|
      assert_equal :generic_repetition, capture([[1], binds]).kind
    end
    assert_equal :unknown, capture([nil, nil]).confidence
  end

  def test_late_values_affect_classification_beyond_samples
    detection = capture(Array.new(100) { [1] } + [[2]])
    assert_equal :suspected_association_n_plus_one, detection.kind
    assert_equal 101, detection.count
    assert_equal 5, detection.queries.size
    assert_equal :generic_repetition, capture(Array.new(10) { [1] } + [nil]).kind
  end

  def test_literals_are_compared_without_retaining_values
    detector = AndOne::Detector.new
    %w[secret-one secret-two].each do |secret|
      detector.record(sql: "SELECT comments.* FROM comments WHERE comments.body = '#{secret}'")
    end
    detection = detector.finish.first
    assert_equal :suspected_association_n_plus_one, detection.kind
    refute_includes detection.inspect, "secret-"
    assert_equal :duplicate_identical_read, capture([nil, nil], sql: "SELECT * FROM comments WHERE body = 'private'").kind
  end

  def test_supported_literal_syntax_across_dialects
    { "postgresql" => ["'private'", "$$private$$", "42", "true"],
      "mysql2" => ["'private'", "42", "true"],
      "sqlite3" => ["'private'", "42", "true"] }.each do |adapter, literals|
      literals.each do |literal|
        evidence = AndOne::RepetitionEvidence.new
        2.times { evidence.record("SELECT * FROM comments WHERE body = #{literal}", {}, adapter, "key") }
        assert_equal %i[duplicate_identical_read observed], evidence.classification, "#{adapter}: #{literal}"
      end
    end
  end

  def test_oversized_sql_abstains_without_changing_counts
    detection = capture([nil, nil], sql: "SELECT * FROM comments WHERE body = '#{"x" * 8192}'")
    assert_equal :generic_repetition, detection.kind
    assert_equal 2, detection.count
  end

  def test_ambiguous_literals_abstain
    ['SELECT * FROM comments WHERE body = "private"',
     "SELECT * FROM comments WHERE body = 'back\\slash'"].each do |sql|
      assert_equal :generic_repetition, capture([nil, nil], sql: sql).kind
    end
  end

  def test_count_and_exists_are_not_record_loading
    ["SELECT COUNT(*) FROM comments WHERE comments.post_id = ?",
     "SELECT 1 AS one FROM comments WHERE comments.post_id = ? LIMIT 1",
     "SELECT EXISTS(SELECT 1 FROM comments WHERE comments.post_id = ?)",
     "SELECT SUM(id) FROM comments WHERE comments.post_id = ?"].each do |sql|
      detection = capture([[1], [2]], sql: sql)
      assert_equal :repeated_aggregate, detection.kind
      suggestion = AndOne::AssociationResolver.resolve(detection, [])
      refute suggestion.actionable?
      assert_nil suggestion.strict_loading_hint
    end
  end

  def test_numbered_placeholders_require_unambiguous_order
    ["$1", "?1"].each do |placeholder|
      sql = SQL.sub("?", placeholder)
      assert_equal :duplicate_identical_read, capture([[1], [1]], sql: sql).kind
    end
    ["$2", "?2", ":named", "$1 OR comments.post_id = $1"].each do |placeholder|
      assert_equal :generic_repetition, capture([[1, 2], [1, 2]], sql: SQL.sub("?", placeholder)).kind
    end
  end

  def test_non_record_and_complex_queries_remain_generic
    ["SELECT body FROM comments WHERE comments.post_id = ?",
     "SELECT body AS one FROM comments WHERE comments.post_id = ?",
     "SELECT comments.* FROM comments JOIN posts ON posts.id = comments.post_id WHERE posts.id = ?"].each do |sql|
      assert_equal :generic_repetition, capture([[1], [2]], sql: sql).kind
    end
  end

  def test_threshold_and_ignores_are_unchanged
    assert_nil capture([[1], [1]], min_n_queries: 3)
    assert_nil capture([[1], [2]], ignore_queries: [/comments/])
  end

  def test_output_and_persistence_expose_only_classification
    detection = capture([["private-bind"], ["private-bind"]])
    AndOne.aggregate.record_many([detection])
    stored = AndOne.aggregate.detections.values.first.detection
    assert_equal detection.kind, stored.kind
    assert_equal detection.confidence, stored.confidence
    json = AndOne::JsonFormatter.new.format([stored])
    assert_equal "duplicate_identical_read", JSON.parse(json)["kind"]
    assert_equal "observed", JSON.parse(json)["confidence"]
    assert_includes AndOne::Formatter.new.format([stored]), stored.classification_label
    assert_includes AndOne::DevToast.render_fallback([stored]), stored.classification_label
    assert_includes AndOne::DevToast.render_toast([stored]), stored.classification_label
    assert_includes AndOne.aggregate.summary, stored.classification_label
    dashboard = AndOne::DevUI.new(->(_) { [200, {}, []] })
    _, _, body = dashboard.call("PATH_INFO" => "/__and_one", "REMOTE_ADDR" => "127.0.0.1")
    assert_includes body.join, stored.classification_label
    output, = capture_io { AndOne.send(:report_annotations, [stored]) }
    assert_includes output, stored.classification_label
    refute_includes json, "private-bind"
    Dir.glob(File.join(@aggregate_tmpdir, "**", "*")).select { |path| File.file?(path) }.each do |path|
      refute_includes File.read(path), "private-bind"
    end
  end

  def test_signatures_are_scan_local_and_storage_is_constant_size
    first = AndOne::RepetitionEvidence.new
    second = AndOne::RepetitionEvidence.new
    1000.times { |id| first.record(SQL, { type_casted_binds: [id] }, "sqlite3", "key-one") }
    second.record(SQL, { type_casted_binds: [0] }, "sqlite3", "key-two")
    assert_equal 32, first.instance_variable_get(:@first).bytesize
    refute_equal first.instance_variable_get(:@first), second.instance_variable_get(:@first)
    assert_equal %i[@first @missing @structure @varying], first.instance_variables.sort
  end

  def test_comment_whitespace_and_keyword_case_do_not_imply_value_variation
    evidence = AndOne::RepetitionEvidence.new
    ["SELECT * FROM comments WHERE id = 1", "select  * from comments /* ignored */ where id = 1"].each do |sql|
      evidence.record(sql, {}, "postgresql", "key")
    end
    assert_equal %i[duplicate_identical_read observed], evidence.classification
  end

  def test_legacy_construction_defaults_to_unknown
    detection = AndOne::Detection.new(queries: [SQL], count: 2)
    assert_equal :generic_repetition, detection.kind
    assert_equal :unknown, detection.confidence
  end

  def test_real_prepared_active_record_queries
    Comment.count # warm schema before capturing
    detections = AndOne.scan { [1, 2, 3].each { |id| Comment.where(post_id: id).to_a } }
    assert_equal :suspected_association_n_plus_one, detections.first.kind
    detections = AndOne.scan { 3.times { Comment.where(post_id: 1).to_a } }
    assert_equal :duplicate_identical_read, detections.first.kind
  end
end
