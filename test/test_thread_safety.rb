# frozen_string_literal: true

require "test_helper"
require "tempfile"

# Thread-safety stress tests that simulate Puma-style concurrent request handling.
# These tests verify that AndOne behaves correctly when multiple threads are
# simultaneously scanning for N+1 queries — the primary concern for production
# use behind Puma's threaded worker pool.
#
# NOTE: Uses a file-based SQLite database because in-memory SQLite databases
# are per-connection and not visible across threads. This mirrors real-world
# usage where PostgreSQL/MySQL are naturally shared across connections.
class TestThreadSafety < Minitest::Test
  include AndOneTestHelper

  THREAD_COUNT = 8
  ITERATIONS = 3

  def setup
    super

    # Switch to a file-based SQLite DB so threads share the same data
    @db_file = Tempfile.new(["and_one_test", ".sqlite3"])
    ActiveRecord::Base.establish_connection(
      adapter: "sqlite3",
      database: @db_file.path,
      pool: THREAD_COUNT + 2
    )

    ActiveRecord::Schema.define do
      create_table :authors, force: true do |t|
        t.string :name
      end
      create_table :posts, force: true do |t|
        t.string :title
        t.references :author, foreign_key: true
      end
      create_table :comments, force: true do |t|
        t.string :body
        t.references :post, foreign_key: true
      end
    end

    seed_data!
  end

  def teardown
    super
    Comment.delete_all
    Post.delete_all
    Author.delete_all

    # Restore the in-memory database for other tests
    ActiveRecord::Base.establish_connection(
      adapter: "sqlite3",
      database: ":memory:"
    )
    ActiveRecord::Schema.define do
      create_table :authors, force: true do |t|
        t.string :name
      end
      create_table :posts, force: true do |t|
        t.string :title
        t.references :author, foreign_key: true
      end
      create_table :comments, force: true do |t|
        t.string :body
        t.references :post, foreign_key: true
      end
    end

    @db_file.close
    @db_file.unlink
  end

  # Helper to run threads and collect errors
  def run_threads(count = THREAD_COUNT, &block)
    errors = []
    threads = count.times.map do |i|
      Thread.new(i) do |idx|
        block.call(idx, errors)
      rescue => e
        errors << "Thread #{idx}: #{e.class}: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
      end
    end
    threads.each(&:join)
    errors
  end

  # Core test: multiple threads scanning simultaneously should each get
  # their own independent detections with no cross-contamination.
  def test_concurrent_scans_are_isolated
    errors = run_threads do |idx, errs|
      ITERATIONS.times do
        detections = AndOne.scan do
          Post.all.each { |post| post.comments.to_a }
        end

        unless detections.is_a?(Array) && detections.size >= 1
          errs << "Thread #{idx}: expected detections, got #{detections.inspect}"
        end

        tables = detections.map(&:table_name)
        unless tables.include?("comments")
          errs << "Thread #{idx}: expected 'comments' table, got #{tables.inspect}"
        end
      end
    end

    assert errors.empty?, "Thread-safety violations:\n#{errors.join("\n")}"
  end

  # Verify scanning state doesn't leak between threads.
  def test_scanning_state_is_thread_local
    barrier = Queue.new
    errors = []

    thread_a = Thread.new do
      AndOne.scan do
        barrier << :a_scanning
        sleep 0.05
        Post.all.each { |post| post.comments.to_a }
      end
    rescue => e
      errors << "Thread A: #{e.class}: #{e.message}"
    end

    thread_b = Thread.new do
      barrier.pop
      if AndOne.scanning?
        errors << "Thread B: scanning? returned true, but only Thread A should be scanning"
      end
      if AndOne.paused?
        errors << "Thread B: paused? leaked from another thread"
      end
    rescue => e
      errors << "Thread B: #{e.class}: #{e.message}"
    end

    [thread_a, thread_b].each(&:join)
    assert errors.empty?, "State leakage:\n#{errors.join("\n")}"
  end

  # Verify pause/resume is thread-local.
  def test_pause_state_is_thread_local
    errors = []
    barrier = Queue.new

    thread_a = Thread.new do
      AndOne.scan do
        AndOne.pause
        barrier << :a_paused
        sleep 0.05
        AndOne.resume
      end
    rescue => e
      errors << "Thread A: #{e.class}: #{e.message}"
    end

    thread_b = Thread.new do
      barrier.pop
      AndOne.scan do
        if AndOne.paused?
          errors << "Thread B: paused? leaked from Thread A"
        end
        Post.all.each { |post| post.comments.to_a }
      end
    rescue => e
      errors << "Thread B: #{e.class}: #{e.message}"
    end

    [thread_a, thread_b].each(&:join)
    assert errors.empty?, "Pause state leakage:\n#{errors.join("\n")}"
  end

  # Threads with N+1s and threads without should not cross-contaminate.
  def test_mixed_n_plus_one_and_clean_threads
    errors = run_threads do |idx, errs|
      if idx.even?
        detections = AndOne.scan do
          Post.all.each { |post| post.comments.to_a }
        end
        unless detections.size >= 1
          errs << "Thread #{idx} (N+1): expected detections, got #{detections.size}"
        end
      else
        detections = AndOne.scan do
          Post.includes(:comments).each { |post| post.comments.to_a }
        end
        unless detections.empty?
          errs << "Thread #{idx} (clean): expected 0 detections, got #{detections.size}: #{detections.map(&:table_name)}"
        end
      end
    end

    assert errors.empty?, "Cross-contamination:\n#{errors.join("\n")}"
  end

  # Aggregate mode under concurrent access: the Mutex should prevent
  # lost updates or corrupted state.
  def test_aggregate_mode_under_concurrency
    AndOne.aggregate_mode = true

    errors = run_threads do |idx, errs|
      ITERATIONS.times do
        AndOne.scan do
          Post.all.each { |post| post.comments.to_a }
        end
      end
    end

    assert errors.empty?, "Aggregate errors:\n#{errors.join("\n")}"

    agg = AndOne.aggregate
    refute agg.empty?, "Aggregate should have entries"

    total = agg.detections.values.sum(&:occurrences)
    expected = THREAD_COUNT * ITERATIONS
    assert_equal expected, total,
      "Expected #{expected} total occurrences, got #{total}"
  end

  # Verify aggregate.record is atomic — concurrent record calls should
  # not lose counts.
  def test_aggregate_record_atomicity
    aggregate = AndOne::Aggregate.new

    # Get a real detection to use
    detections = AndOne.scan do
      Post.all.each { |post| post.comments.to_a }
    end
    sample_detection = detections.first
    assert sample_detection, "Need a detection for this test"

    record_count = 100
    threads = THREAD_COUNT.times.map do
      Thread.new do
        record_count.times { aggregate.record(sample_detection) }
      end
    end
    threads.each(&:join)

    entry = aggregate.detections.values.first
    expected = THREAD_COUNT * record_count
    assert_equal expected, entry.occurrences,
      "Expected #{expected} occurrences, got #{entry.occurrences} (lost updates!)"
  end

  # Verify that notifications_callback is called safely from concurrent threads.
  def test_notifications_callback_under_concurrency
    mutex = Mutex.new
    callback_calls = []

    AndOne.notifications_callback = ->(dets, msg) do
      mutex.synchronize { callback_calls << Thread.current.object_id }
    end

    errors = run_threads do |idx, errs|
      AndOne.scan do
        Post.all.each { |post| post.comments.to_a }
      end
    end

    assert errors.empty?, "Callback errors:\n#{errors.join("\n")}"

    assert_equal THREAD_COUNT, callback_calls.size,
      "Expected #{THREAD_COUNT} callback calls, got #{callback_calls.size}"

    unique_threads = callback_calls.uniq.size
    assert unique_threads > 1,
      "Expected callbacks from multiple threads, got #{unique_threads} unique"
  end

  # Stress test: rapid start/finish cycles across threads.
  def test_rapid_scan_lifecycle
    errors = run_threads do |idx, errs|
      (ITERATIONS * 3).times do
        AndOne.scan do
          Post.first
        end
      end
    end

    assert errors.empty?, "Lifecycle errors:\n#{errors.join("\n")}"
  end

  # Verify that error handling during scan doesn't leave stale state
  # that affects other threads.
  def test_error_during_scan_cleans_up
    errors = []
    barrier = Queue.new

    thread_a = Thread.new do
      begin
        AndOne.scan do
          barrier << :started
          raise "boom"
        end
      rescue RuntimeError
        # Expected
      end
      if AndOne.scanning?
        errors << "Thread A: still scanning after error"
      end
    end

    thread_b = Thread.new do
      barrier.pop
      sleep 0.02

      detections = AndOne.scan do
        Post.all.each { |post| post.comments.to_a }
      end

      unless detections.is_a?(Array) && detections.size >= 1
        errors << "Thread B: scanning failed after Thread A's error"
      end
    rescue => e
      errors << "Thread B: #{e.class}: #{e.message}"
    end

    [thread_a, thread_b].each(&:join)
    assert errors.empty?, "Error cleanup issues:\n#{errors.join("\n")}"
  end

  # Verify that the ignore_list singleton is safely shared.
  def test_ignore_list_concurrent_access
    errors = run_threads do |idx, errs|
      ITERATIONS.times do
        list = AndOne.ignore_list
        unless list.is_a?(AndOne::IgnoreFile)
          errs << "Thread #{idx}: got #{list.class} instead of IgnoreFile"
        end
      end
    end

    assert errors.empty?, "IgnoreFile errors:\n#{errors.join("\n")}"
  end

  # Verify AssociationResolver's table_model_cache is thread-safe.
  def test_association_resolver_cache_under_concurrency
    # Clear any existing cache
    if AndOne::AssociationResolver.instance_variable_defined?(:@table_model_cache)
      AndOne::AssociationResolver.instance_variable_set(:@table_model_cache, {})
    end

    errors = run_threads do |idx, errs|
      ITERATIONS.times do
        model = AndOne::AssociationResolver.model_for_table("comments")
        unless model == Comment
          errs << "Thread #{idx}: expected Comment, got #{model.inspect}"
        end

        model2 = AndOne::AssociationResolver.model_for_table("posts")
        unless model2 == Post
          errs << "Thread #{idx}: expected Post, got #{model2.inspect}"
        end
      end
    end

    assert errors.empty?, "Cache errors:\n#{errors.join("\n")}"
  end

  # Simulate Puma-like request handling: middleware wrapping concurrent requests.
  def test_simulated_puma_requests
    middleware = AndOne::Middleware.new(->(env) {
      if env["n_plus_one"]
        Post.all.each { |post| post.comments.to_a }
      else
        Post.includes(:comments).each { |post| post.comments.to_a }
      end
      [200, {}, ["OK"]]
    })

    errors = run_threads do |idx, errs|
      ITERATIONS.times do
        env = { "n_plus_one" => idx.even? }
        status, _, body = middleware.call(env)
        unless status == 200
          errs << "Thread #{idx}: got status #{status}"
        end
      end
    end

    assert errors.empty?, "Puma simulation errors:\n#{errors.join("\n")}"
  end

  # Verify detection counts are accurate per-thread (no inflation from
  # other threads' queries leaking in).
  def test_detection_counts_are_accurate
    post_count = Post.count

    errors = run_threads do |idx, errs|
      detections = AndOne.scan do
        Post.all.each { |post| post.comments.to_a }
      end

      detection = detections.find { |d| d.table_name == "comments" }
      if detection
        if detection.count > post_count
          errs << "Thread #{idx}: count #{detection.count} exceeds post_count #{post_count} — possible cross-thread leak"
        end
      else
        errs << "Thread #{idx}: no comments detection found"
      end
    end

    assert errors.empty?, "Count accuracy:\n#{errors.join("\n")}"
  end

  # High-contention stress test: many threads, many iterations, aggregate mode,
  # callbacks — everything at once.
  def test_full_stress
    AndOne.aggregate_mode = true

    mutex = Mutex.new
    callback_count = 0

    AndOne.notifications_callback = ->(_dets, _msg) do
      mutex.synchronize { callback_count += 1 }
    end

    errors = run_threads(THREAD_COUNT * 2) do |idx, errs|
      (ITERATIONS * 2).times do
        case idx % 3
        when 0
          AndOne.scan { Post.all.each { |p| p.comments.to_a } }
        when 1
          AndOne.scan { Post.all.each { |p| p.author } }
        when 2
          AndOne.scan { Post.includes(:comments, :author).each { |p| p.comments.to_a; p.author } }
        end
      end
    end

    assert errors.empty?, "Full stress errors:\n#{errors.join("\n")}"

    refute AndOne.aggregate.empty?, "Aggregate should have collected entries"

    assert callback_count >= 1, "Expected at least 1 callback, got #{callback_count}"

    summary = AndOne.aggregate.summary
    assert_includes summary, "AndOne Session Summary"
  end
end
