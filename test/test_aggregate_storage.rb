# frozen_string_literal: true

require "test_helper"

class TestAggregateStorage < Minitest::Test
  include AndOneTestHelper

  def detection(index = 0, large: false)
    AndOne::Detection.new(queries: Array.new(20) { "SELECT * FROM posts WHERE id = #{index} #{"x" * (large ? 10_000 : 0)}" },
                          raw_caller_strings: Array.new(100) { "app/example.rb:#{index}:#{"x" * 1000}" }, count: 100)
  end

  def test_memory_is_default_and_bounded
    aggregate = AndOne::Aggregate.new
    (AndOne::Aggregate::MAX_ENTRIES + 5).times { |index| aggregate.record(detection(index, large: true)) }
    assert_equal AndOne::Aggregate::MAX_ENTRIES, aggregate.size
    refute aggregate.detections.key?(detection(0, large: true).issue_id)
    stored = aggregate.detections.values.last.detection
    assert_equal 100, stored.count
    assert_equal 5, stored.queries.size
    assert(stored.queries.all? { |sql| sql.bytesize <= AndOne::Aggregate::MAX_SQL_BYTES })
    assert_equal 20, stored.raw_caller_strings.size
    assert(stored.raw_caller_strings.all? { |frame| frame.bytesize <= AndOne::Aggregate::MAX_FRAME_BYTES })
    assert_equal detection(104, large: true).fingerprint, stored.fingerprint
  end

  def test_file_retention_bounds_large_payloads_and_keeps_original_identity
    aggregate = AndOne::Aggregate.new(path: @aggregate_tmpdir, strict: true)
    batch = Array.new(105) { |index| detection(index, large: true) }
    aggregate.record_many(batch)
    stored = aggregate.detections
    assert_equal 100, stored.size
    refute stored.key?(batch.first.issue_id)
    assert_equal batch.last.fingerprint, stored.fetch(batch.last.issue_id).detection.fingerprint
    assert File.size(File.join(@aggregate_tmpdir, "aggregate.json")) <= AndOne::AggregateStore::FileStore::MAX_BYTES
    assert_equal batch.last.count, stored.fetch(batch.last.issue_id).detection.count
  end

  def test_one_transaction_per_scan_and_round_trip
    store = AndOne::AggregateStore::FileStore.new(@aggregate_tmpdir)
    calls = 0
    transaction = store.method(:transaction)
    store.define_singleton_method(:transaction) do |&block|
      calls += 1
      transaction.call(&block)
    end
    aggregate = AndOne::Aggregate.new(store: store)
    batch = [detection(1), detection(2)]
    assert_equal batch, aggregate.record_many(batch)
    assert_empty aggregate.record_many(batch)
    assert_equal 2, calls
    reader = AndOne::Aggregate.new(path: @aggregate_tmpdir)
    assert_equal [2, 2], reader.detections.values.map(&:occurrences)
    assert File.size(File.join(@aggregate_tmpdir, "aggregate.json")) <= AndOne::AggregateStore::FileStore::MAX_BYTES
    return if Gem.win_platform?

    %w[aggregate.json aggregate.lock].each do |name|
      assert_equal 0o600, File.stat(File.join(@aggregate_tmpdir, name)).mode & 0o777
    end
  end

  def test_independent_processes_and_preloaded_store_preserve_counts
    skip "fork unavailable" unless Process.respond_to?(:fork)

    aggregate = AndOne::Aggregate.new(path: @aggregate_tmpdir, strict: true)
    aggregate.record(detection)
    children = 3.times.map do
      fork do
        # One inherited store and one independently constructed store per child.
        fresh = AndOne::Aggregate.new(path: @aggregate_tmpdir, strict: true)
        5.times do
          aggregate.record(detection)
          fresh.record(detection)
        end
        exit! 0
      end
    end
    children.each { |pid| assert Process.wait2(pid).last.success? }
    assert_equal 31, aggregate.detections.values.first.occurrences
  end

  def test_malformed_and_oversized_data_is_not_silently_replaced
    path = File.join(@aggregate_tmpdir, "aggregate.json")
    ["{broken", "[]", '{"bad":{}}', " " * (AndOne::AggregateStore::FileStore::MAX_BYTES + 1)].each do |input|
      File.write(path, input)
      aggregate = AndOne::Aggregate.new(path: @aggregate_tmpdir)
      _out, err = capture_io do
        2.times { assert aggregate.record(detection) }
        assert_empty aggregate.detections
      end
      assert_equal 1, err.lines.size
      assert_equal input, File.read(path)
      aggregate.reset!
      assert_equal({}, JSON.parse(File.read(path)))
      assert aggregate.record(detection)
    end
  end

  def test_missing_directory_is_created_lazily_and_open_failures_are_best_effort
    path = File.join(@aggregate_tmpdir, "nested/store")
    aggregate = AndOne::Aggregate.new(path: path)
    refute File.exist?(path)
    assert aggregate.record(detection)
    assert File.exist?(File.join(path, "aggregate.json"))
    File.stub(:open, ->(*) { raise Errno::EACCES }) do
      _out, err = capture_io { assert aggregate.record(detection) }
      assert_includes err, "Errno::EACCES"
      assert_raises(Errno::EACCES) { AndOne::Aggregate.new(path: path, strict: true).record(detection) }
    end
  end

  def test_interrupted_replace_preserves_previous_document_and_cleans_temp
    aggregate = AndOne::Aggregate.new(path: @aggregate_tmpdir)
    aggregate.record(detection)
    path = File.join(@aggregate_tmpdir, "aggregate.json")
    before = File.read(path)
    File.stub(:rename, ->(*) { raise IOError, "interrupted" }) do
      capture_io { assert aggregate.record(detection(2)) }
    end
    assert_equal before, File.read(path)
    refute File.exist?("#{path}.tmp")
    assert aggregate.record(detection(2))
    assert_equal 2, aggregate.size
  end

  def test_partial_temp_write_preserves_previous_document
    aggregate = AndOne::Aggregate.new(path: @aggregate_tmpdir)
    aggregate.record(detection)
    path = File.join(@aggregate_tmpdir, "aggregate.json")
    before = File.read(path)
    open_file = File.method(:open)
    failing_open = lambda do |name, *args, &block|
      open_file.call(name, *args) do |file|
        if name.end_with?(".tmp")
          original_write = file.method(:write)
          file.define_singleton_method(:write) { |output| original_write.call(output.byteslice(0, 10)) }
        end
        block.call(file)
      end
    end
    File.stub(:open, failing_open) { capture_io { assert aggregate.record(detection(2)) } }
    assert_equal before, File.read(path)
    refute File.exist?("#{path}.tmp")
  end

  def test_failed_storage_does_not_suppress_enforcement_or_delivery
    store = Object.new
    def store.transaction
      raise IOError, "private filesystem details"
    end
    AndOne.instance_variable_set(:@aggregate, AndOne::Aggregate.new(store: store))
    received = []
    AndOne.notifications_callback = ->(items, *) { received.concat(items) }
    AndOne.raise_on_detect = true
    _out, err = capture_io do
      assert_raises(AndOne::NPlus1Error) { AndOne.send(:report, [detection]) }
    end
    assert_equal 1, received.size
    assert_includes err, "storage failed"
    refute_includes err, "private filesystem details"
    AndOne.raise_on_detect = false
    AndOne.send(:report, [detection])
    assert_equal 2, received.size
  end
end
