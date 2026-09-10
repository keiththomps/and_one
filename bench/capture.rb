# frozen_string_literal: true

# Synthetic notification benchmark: no DB latency, reporting, or persistence.
# Run with: bundle exec ruby bench/capture.rb
require "json"
require_relative "../lib/and_one"

module CaptureBenchmark
  module_function

  def clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def emit(queries, mode)
    queries.times do |i|
      table = mode == :active_clean ? "items_#{i}" : "items"
      ActiveSupport::Notifications.instrument("sql.active_record", name: "Load", sql: "SELECT * FROM #{table} WHERE id = #{i}")
    end
  end

  def workload(mode, queries)
    retained = [0, 0]
    AndOne.capture_for_test do
      emit(queries, mode)
      detector = AndOne::ExecutionContext.active_detector
      if detector
        # Inspect internal storage, including clean groups that produce no finding.
        samples = detector.instance_variable_get(:@groups).values.flat_map(&:queries)
        retained = [samples.size, samples.sum(&:bytesize)]
      end
    end
    retained
  end

  def run_scans(mode, scans, queries)
    latencies = []
    peak = [0, 0]
    scans.times do
      began = clock
      samples, bytes = workload(mode, queries)
      latencies << ((clock - began) * 1000)
      peak = [[peak[0], samples].max, [peak[1], bytes].max]
    end
    [latencies, peak]
  end

  def measure(mode, concurrency, scans, queries)
    AndOne.enabled = mode != :disabled
    ready = Queue.new
    start = Queue.new
    workers = Array.new(concurrency) do
      Thread.new do
        ready << true
        start.pop
        run_scans(mode, scans, queries)
      end
    end
    concurrency.times { ready.pop }
    GC.start
    allocated = GC.stat(:total_allocated_objects)
    began = clock
    concurrency.times { start << true }
    results = workers.map(&:value)
    elapsed = clock - began
    allocations = GC.stat(:total_allocated_objects) - allocated
    latencies = results.flat_map(&:first)
    {
      mode: mode, concurrency: concurrency, scans_per_thread: scans, queries_per_scan: queries,
      elapsed_seconds: elapsed, notifications_per_second: concurrency * scans * queries / elapsed,
      allocated_objects: allocations, allocations_per_notification: allocations.fdiv(concurrency * scans * queries),
      scan_latency_ms: { mean: latencies.sum / latencies.size, max: latencies.max },
      max_retained_samples_per_scan: results.map { |r| r.last.first }.max,
      max_retained_sql_bytes_per_scan: results.map { |r| r.last.last }.max
    }
  end

  def run
    scans = Integer(ENV.fetch("SCANS", "100"))
    queries = Integer(ENV.fetch("QUERIES", "30"))
    concurrency = ENV.fetch("CONCURRENCY", "1,4,16").split(",").map { |value| Integer(value) }
    abort "SCANS, QUERIES and CONCURRENCY must be positive" unless [scans, queries, *concurrency].all?(&:positive?)

    # Warm parser/subscriber/configuration paths before measuring.
    AndOne.capture_for_test { emit(queries, :active_n_plus_one) }
    %i[disabled active_clean active_n_plus_one].each do |mode|
      concurrency.each { |threads| puts JSON.generate(measure(mode, threads, scans, queries)) }
    end
  end
end

CaptureBenchmark.run
