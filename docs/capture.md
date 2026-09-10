# SQL capture boundaries and cost

## Execution context

A scan belongs to the **current Ruby fiber**, not every fiber in its thread.
AndOne's internal `ExecutionContext` deliberately uses Ruby's fiber-local
`Thread#[]` storage, independently of ActiveSupport's configurable isolation
level. Interleaved fibers and concurrent threads do not share a detector or pause
state. Nested scans in the same fiber reuse the outer scan; nested pause blocks
restore the previous state. Exceptions, `return`, `break`, and `throw` release an
owned scan without reporting incomplete results.

Child fibers and child threads **do not inherit** a scan or its pause state. Wrap
synchronous work in its own `AndOne.scan` inside the child if needed. Results are
independent; they are not merged into the parent's results. Do not copy the
internal detector between execution contexts. Automatic propagation is not
supported. Request/job wrappers cover synchronous SQL while invoking the app/job,
not subsequent lazy response-body enumeration or detached work.

### ActiveRecord `load_async`

Background SQL is **unsupported** for N+1 attribution. Events with `async: true`
are deliberately excluded, even if delivered in an active scan. Rails can buffer
worker SQL notifications and publish them when a caller consumes the result:
that stack identifies result consumption, not the initiating query, and may be
inside a completely different scan. Merely looking up the current detector would
produce false attribution.

`load_async` that falls back to ordinary synchronous execution (`async: false` or
absent) is captured normally if its notification is emitted in the scan's fiber.
Consequently async workload detection can depend on executor/fallback behavior;
it is **not** a reliable test of async N+1s. Use explicit synchronous workloads
when asserting query behavior. No mutable state is propagated to workers, and no
per-query warnings are emitted. The real file-backed SQLite regression test
verifies worker execution, deferred caller-thread notification, exclusion from
an unrelated consumer scan, and synchronous fallback on the installed Rails
version. It does not promise identical notification internals across all Rails
versions/adapters.

## Subscriber and retention

Requiring AndOne installs one process-lifetime `sql.active_record` subscriber.
Installation is mutex-protected and idempotent. Starting/finishing scans never
adds/removes listeners, including on exceptions; cleanup releases only the
fiber's detector. Inactive/paused contexts return before SQL parsing, connection
metadata, or stack capture. Cached and schema events are excluded as before.

Each (full call-stack location, configured connection, normalized SQL shape)
group retains an exact occurrence counter, the **first five SQL samples**, and
one representative stack/metadata record. `Detection#count` is the total, while
`Detection#queries` is now a bounded sample, not a complete query history. Text,
JSON, and aggregate storage continue to use the exact count. Stack locations
must still be captured per eligible event to preserve existing full-stack
location/ignore semantics, but later occurrences do not replace retained stacks
or metadata. No bind objects or connection objects are retained.

This bounds repeated-occurrence retention, **not total scan memory**: distinct
shapes/stacks/connections still create groups, and individual SQL strings and
stack depth are not byte-capped. SQL parsing and stack fingerprinting still cost
work per eligible event. Global storage retention and SQL redaction are separate
concerns; do not treat these samples as sanitized SQL.

Configured `ignore_queries` regexes continue excluding individual events before
counting. Ignore-file `query:` rules instead suppress a whole repeated group if
**any** occurrence matches, including SQL arriving after the sample limit. They
are evaluated during capture against the ignore-list instance selected at scan
start. Reload ignore files between scans, not during a scan. Other ignore rules
and thresholds continue to apply normally.

## Reproducible benchmark

```sh
bundle exec ruby bench/capture.rb
SCANS=200 QUERIES=100 CONCURRENCY=1,4,16 bundle exec ruby bench/capture.rb
```

The standalone harness emits JSONL for disabled, active-clean (distinct shapes
with no repetition), and active-N+1 workloads at each concurrency. Output reports
process-wide allocations, allocations per notification, throughput, mean/max scan
latency, and maximum retained sample count/SQL bytes per scan (including clean
groups). It warms capture paths and excludes reporting/persistence and database
latency. Threads run concurrently but remain subject to the Ruby VM/GVL; this is
a capture-overhead benchmark, not a database or Puma capacity estimate. Compare
runs on the same Ruby/machine with the same parameters. There are no wall-clock
CI thresholds, timer threads, or background queues in capture itself.

Example local run (Ruby 4.0.6, Rails 8.1.2, Linux x86_64;
`SCANS=20 QUERIES=30 CONCURRENCY=1,4,16`):

| Workload | Threads | Notifications/s | Allocations/notification | Mean scan ms | Retained samples/scan |
|---|---:|---:|---:|---:|---:|
| disabled | 1 | 333737 | 9.8 | 0.09 | 0 |
| disabled | 4 | 366592 | 9.8 | 0.08 | 0 |
| disabled | 16 | 378950 | 9.8 | 0.08 | 0 |
| active_clean | 1 | 12180 | 286.9 | 2.46 | 30 |
| active_clean | 4 | 12484 | 286.9 | 2.40 | 30 |
| active_clean | 16 | 12444 | 286.9 | 2.41 | 30 |
| active_n_plus_one | 1 | 22388 | 177.9 | 1.33 | 5 |
| active_n_plus_one | 4 | 20965 | 177.9 | 1.43 | 5 |
| active_n_plus_one | 16 | 22616 | 177.9 | 1.33 | 5 |

These are illustrative measurements, not a speedup claim or performance guarantee.
