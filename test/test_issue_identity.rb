# frozen_string_literal: true

require "test_helper"

class TestIssueIdentity < Minitest::Test
  include AndOneTestHelper

  def test_identity_separates_locations_but_not_values_or_deployment_roots
    first = detection("/srv/one/app/models/post.rb:10:in 'comments'", value: 1)
    same = detection("/home/two/app/models/post.rb:10:in 'comments'", value: 2)
    other = detection("/srv/one/app/controllers/posts_controller.rb:20:in 'index'")
    assert_equal first.fingerprint, other.fingerprint
    assert_equal first.issue_id, same.issue_id
    refute_equal first.issue_id, other.issue_id
    assert_equal "app/models/post.rb:10", first.normalized_origin
    refute_equal first.issue_id, detection(first.origin_frame, connection_id: "secondary").issue_id
  end

  def test_application_root_paths_and_missing_locations
    first = detection("#{Dir.pwd}/jobs/load.rb:3:in 'perform'")
    assert_equal "jobs/load.rb:3", first.normalized_origin
    assert_equal "external.rb:5", detection("/other/place/external.rb:5").normalized_origin
    assert_nil detection(nil).normalized_origin
    assert_equal detection(nil).issue_id, detection(nil, value: 2).issue_id
  end

  def test_aggregate_round_trips_both_identities_and_occurrences
    first, other = locations
    assert AndOne.aggregate.record(first)
    assert AndOne.aggregate.record(other)
    refute AndOne.aggregate.record(detection(first.origin_frame, value: 2))

    reader = AndOne::Aggregate.new(path: @aggregate_tmpdir)
    entries = reader.detections
    assert_equal [first.issue_id, other.issue_id].sort, entries.keys.sort
    assert_equal 2, entries[first.issue_id].occurrences
    assert_equal 1, entries[other.issue_id].occurrences
    assert_equal first.fingerprint, entries[first.issue_id].detection.fingerprint
    assert_equal first.connection_id, entries[first.issue_id].detection.connection_id
    persisted = JSON.parse(File.read(File.join(@aggregate_tmpdir, "aggregate.json")))
    assert_equal first.fingerprint, persisted[first.issue_id]["detection"]["fingerprint"]
    assert_equal first.issue_id, persisted[first.issue_id]["detection"]["issue_id"]
  end

  def test_legacy_shape_keyed_entries_remain_readable_and_are_rekeyed
    first = detection("app/models/post.rb:10", connection_id: nil)
    path = File.join(@aggregate_tmpdir, "aggregate.json")
    File.write(path, JSON.generate(first.fingerprint => {
                                     detection: { queries: first.queries, count: first.count,
                                                  caller_strings: first.raw_caller_strings, adapter: first.adapter },
                                     occurrences: 3
                                   }))
    refute AndOne.aggregate.record(first)
    assert_equal 4, AndOne.aggregate.detections.fetch(first.issue_id).occurrences
    assert_equal [first.issue_id], JSON.parse(File.read(path)).keys
  end

  def test_broad_fingerprint_ignores_still_cover_both_locations
    first, other = locations
    path = File.join(@aggregate_tmpdir, ".and_one_ignore")
    File.write(path, "fingerprint:#{first.fingerprint}\n")
    ignores = AndOne::IgnoreFile.new(path)
    assert ignores.ignored?(first, first.raw_caller_strings)
    assert ignores.ignored?(other, other.raw_caller_strings)
  end

  def test_all_outputs_preserve_locations_and_broad_ignore_key
    first, other = locations
    [first, other].each { |d| AndOne.aggregate.record(d) }
    json = AndOne::JsonFormatter.new.format_hashes([first, other])
    assert_equal([first.issue_id, other.issue_id], json.map { |entry| entry[:issue_id] })
    assert_equal [first.fingerprint], json.map { |entry| entry[:fingerprint] }.uniq
    text = AndOne::Formatter.new.format([first, other])
    html = AndOne::DevUI.new(nil).call("PATH_INFO" => "/__and_one", "REMOTE_ADDR" => "127.0.0.1").last.join
    [text, html, AndOne.aggregate.summary].each do |output|
      [first, other].each do |finding|
        assert_includes output, finding.issue_id
        assert_includes output, finding.fingerprint
        assert_includes output, finding.normalized_origin
      end
    end

    path = File.join(@aggregate_tmpdir, "findings.jsonl")
    writer = AndOne::LogfileWriter.new(path: path, format: :json)
    writer.record([first, other, first])
    writer.flush!
    entries = File.readlines(path).map { |line| JSON.parse(line) }
    assert_equal [first.issue_id, other.issue_id].sort, entries.map { |entry| entry["issue_id"] }.sort
  end

  def test_real_scans_report_distinct_application_locations
    seed_data!
    reports = []
    AndOne.notifications_callback = ->(findings, _) { reports.concat(findings) }
    2.times do
      AndOne.scan { Post.all.each { |post| post.comments.to_a } }
      AndOne.scan { Post.all.each { |post| post.comments.to_a } }
    end
    assert_equal 2, reports.size
    assert_equal 1, reports.map(&:fingerprint).uniq.size
    assert_equal [2, 2], AndOne.aggregate.detections.values.map(&:occurrences)
  ensure
    Comment.delete_all
    Post.delete_all
    Author.delete_all
  end

  private

  def locations
    [detection("app/models/post.rb:10"), detection("app/controllers/posts_controller.rb:20")]
  end

  def detection(frame, value: 1, connection_id: "primary")
    AndOne::Detection.new(queries: ["SELECT * FROM comments WHERE post_id = #{value}"] * 2,
                          count: 2, raw_caller_strings: [frame].compact, adapter: "sqlite3",
                          connection_id: connection_id)
  end
end
