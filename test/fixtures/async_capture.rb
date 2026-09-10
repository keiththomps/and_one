# frozen_string_literal: true

# A real file-backed SQLite pool is required: :memory: disables async support.
require "and_one"
require "timeout"

ActiveRecord.async_query_executor = :global_thread_pool
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: "async.sqlite3", pool: 5)
ActiveRecord::Schema.define { create_table(:widgets) { |t| t.string :name } }
class Widget < ActiveRecord::Base; end
Widget.create!(name: "one")

AndOne.raise_on_detect = true
AndOne.notifications_callback = ->(*) { abort "unexpected reporting" }
caller_thread = Thread.current
notifications = []
subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
  notifications << [Thread.current, payload[:async]] if payload[:name] == "Widget Load"
end

# Observe actual background completion without racing result consumption (which
# is allowed to execute the query synchronously if the worker hasn't started).
completed = Queue.new
observer = Module.new do
  define_method(:execute_or_skip) do
    super()
  ensure
    completed << Thread.current
  end
end
ActiveRecord::FutureResult.prepend(observer)
tracker = ActiveRecord::Base.asynchronous_queries_tracker
tracker.start_session
begin
  relations = nil
  initial = AndOne.capture_for_test do
    relations = 3.times.map { |i| Widget.where(id: i + 1).load_async }
    workers = Timeout.timeout(10) { 3.times.map { completed.pop } }
    abort "not executed by workers" unless workers.all? { |thread| thread != caller_thread }
  end
  abort "scheduled queries attributed to caller" unless initial.empty?
  abort "notifications flushed too early" unless notifications.empty?

  # Rails buffers worker events and publishes them when another scope consumes
  # the result. They must not contaminate that unrelated scan.
  consumed = AndOne.capture_for_test { relations.each(&:to_a) }
  abort "async events contaminated consumer" unless consumed.empty?
  abort "unexpected notification boundary: #{notifications.inspect}" unless notifications.size == 3 && notifications.all? do |thread, async|
    thread == caller_thread && async
  end
  puts "async worker execution; caller notification; excluded from scan"
ensure
  tracker.finalize_session
  ActiveSupport::Notifications.unsubscribe(subscriber)
end

# With the executor disabled, load_async falls back to ordinary synchronous SQL.
ActiveRecord::Base.connection_pool.disconnect!
ActiveRecord.async_query_executor = nil
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: "async.sqlite3")
detections = AndOne.capture_for_test { 3.times { |i| Widget.where(id: i + 1).load_async.to_a } }
abort "synchronous fallback not captured" unless detections.map(&:count) == [3]
puts "synchronous fallback captured"
