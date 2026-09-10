# frozen_string_literal: true

# bundle exec ruby bench/aggregate_storage.rb
# Reports retained growth and 20 scan transactions, not a CI timing assertion.
require "bundler/setup"
require "and_one"
require "tmpdir"

puts "store,history,retained,bytes,20_scans_seconds"
%i[memory file].each do |kind|
  [10, 100, 1000].each do |history|
    Dir.mktmpdir("and_one_benchmark") do |path|
      aggregate = AndOne::Aggregate.new(path: kind == :file ? path : nil, strict: true)
      findings = Array.new(history) do |index|
        AndOne::Detection.new(queries: ["SELECT * FROM posts WHERE id = #{index}"], count: 10,
                              raw_caller_strings: ["app/example.rb:#{index + 1}"])
      end
      findings.each_slice(10) { |batch| aggregate.record_many(batch) }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      20.times { aggregate.record_many(findings.last(10)) }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      bytes = kind == :file ? File.size(File.join(path, "aggregate.json")) : "n/a"
      puts [kind, history, aggregate.size, bytes, elapsed.round(4)].join(",")
    end
  end
end
