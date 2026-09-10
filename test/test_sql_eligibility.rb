# frozen_string_literal: true

require "test_helper"

class TestSqlEligibility < Minitest::Test
  include AndOneTestHelper

  Frame = Struct.new(:path, :lineno)
  class SecondaryRecord < ActiveRecord::Base
    self.abstract_class = true
  end

  def test_read_statements
    ["select * from posts", "SeLeCt * FROM posts", "/* SELECT ignored */ select 1",
     "-- comment\nSELECT 1", "WITH p AS (select * from posts) select * from p",
     'with "p"(id) AS NOT MATERIALIZED (SELECT 1), q AS (SELECT 2) SELECT * FROM q',
     "with recursive p AS (select 1 union all select 2) SELECT * from p",
     "with p AS (with q AS (select 1) select * from q) select * from p;"].each do |sql|
      assert AndOne::ReadStatement.eligible?(sql), sql
      assert_equal 1, notified(sql).size, sql
    end
  end

  def test_writes_and_unsupported_statements_are_not_reads
    ["INSERT INTO posts (title) VALUES ('SELECT')", "update posts set title = 'select'",
     "/* SELECT */ DELETE FROM posts", "WITH p AS (select 1) DELETE FROM posts",
     "WITH p AS (DELETE FROM posts RETURNING *) SELECT * FROM p",
     "SELECT * INTO other FROM posts", "SELECT 1; DELETE FROM posts",
     "EXPLAIN SELECT 1", "WITH p AS (SELECT 1", "SELECT 'unterminated",
     "/* unterminated SELECT"].each do |sql|
      refute AndOne::ReadStatement.eligible?(sql), sql
      assert_empty notified(sql), sql
    end
  end

  def test_schema_cache_and_query_ignore_filters
    assert_empty notified("select 1", name: "SCHEMA")
    assert_empty notified("select 1", cached: true)
    AndOne.ignore_queries = [/select/]
    assert_empty notified("select 1")
  end

  def test_ordered_stack_keys_preserve_path_line_pairing
    detector = AndOne::Detector.allocate
    original = [Frame.new("a.rb", 1), Frame.new("b.rb", 2)]
    swapped = [Frame.new("a.rb", 2), Frame.new("b.rb", 1)]
    key = detector.send(:location_fingerprint, original)
    refute_equal key, detector.send(:location_fingerprint, original.reverse)
    refute_equal key, detector.send(:location_fingerprint, swapped)
    assert_equal key, detector.send(:location_fingerprint, original.map(&:dup))
  end

  def test_real_secondary_connection_attribution_and_grouping
    Dir.mktmpdir do |dir|
      SecondaryRecord.establish_connection(adapter: "sqlite3", database: File.join(dir, "secondary.sqlite3"))
      SecondaryRecord.connection_pool.with_connection do |secondary|
        ActiveRecord::Base.connection_pool.with_connection do |primary|
          connections = [primary, secondary]
          # Identical SQL and call stacks, but neither connection repeats a query.
          assert_empty capture_connections(connections, 1)
          detections = ActiveRecord::Base.stub(:connection_db_config, -> { raise "Do not consult Base" }) do
            capture_connections(connections, 2)
          end
          assert_equal 2, detections.size
          assert_equal [2, 2], detections.map(&:count)
          assert_equal %w[sqlite3 sqlite3], detections.map(&:adapter)
          expected = connections.map { |c| AndOne::ConnectionContext.metadata(connection: c)[:connection_id] }
          assert_equal expected.sort, detections.map(&:connection_id).sort
          assert_equal 2, detections.map(&:connection_id).uniq.size
          assert_equal 1, detections.map(&:fingerprint).uniq.size
          assert_equal 2, detections.map(&:issue_id).uniq.size
        end
      end
    ensure
      SecondaryRecord.remove_connection
    end
  end

  def test_missing_connection_does_not_borrow_base_metadata
    detection = notified("select 1").first
    assert_equal "unknown", detection.adapter
    assert_nil detection.connection_id
  end

  private

  def notified(sql, **payload)
    AndOne.scan do
      2.times { ActiveSupport::Notifications.instrument("sql.active_record", { sql: sql, name: "SQL" }.merge(payload)) }
    end
  end

  def capture_connections(connections, count)
    AndOne.scan do
      connections.each { |connection| count.times { connection.exec_query("select 1") } }
    end
  end
end
