# AndOne — Feature Roadmap

## ✅ Completed

- [x] Core detection engine using `sql.active_record` notifications
- [x] SQL fingerprinting without external dependencies
- [x] Association resolver that suggests exact `.includes()` fixes
- [x] Rich formatted output with query, call stack, and fix suggestions
- [x] Rack middleware that never corrupts error backtraces
- [x] Railtie for zero-config auto-setup in dev/test
- [x] Raises in test env, warns in dev, disabled in production
- [x] Pause/resume support for known N+1s
- [x] ActiveJob `around_perform` hook (works with any backend)
- [x] Sidekiq server middleware (for jobs bypassing ActiveJob)
- [x] `ScanHelper` shared module to DRY up scan lifecycle across entry points
- [x] Double-scan protection (ActiveJob + Sidekiq don't conflict)

## 🎯 High Value — Completed

- [x] **Auto-detect the "fix location"** — Walks the backtrace to identify two key frames: the "origin" (where the N+1 is triggered inside a loop) and the "fix location" (the outer frame where `.includes()` should be added). Both are highlighted in the output.

- [x] **Ignore file (`.and_one_ignore`)** — Supports four rule types: `gem:` (for N+1s from gems like devise/administrate you can't fix), `path:` (glob patterns for app areas), `query:` (SQL patterns), and `fingerprint:` (specific detections). Checked into source control.

- [x] **Aggregate mode for development** — `AndOne.aggregate_mode = true` reports each unique N+1 only once per server session. Tracks occurrence counts. `AndOne.aggregate.summary` shows a session overview. Thread-safe.

- [x] **RSpec / Minitest matchers** — `assert_no_n_plus_one { ... }` / `assert_n_plus_one { ... }` for Minitest. `expect { ... }.not_to cause_n_plus_one` for RSpec. Matchers temporarily disable `raise_on_detect` internally so they work regardless of config.

## ✅ Medium Value — Polish & Power User Features (Completed)

- [x] **`strict_loading` suggestion** — When an N+1 is detected, also suggest the `strict_loading` approach as an alternative: "You could also add `has_many :comments, strict_loading: true` to prevent this at the model level."

- [x] **Query count in test failure messages** — "N+1 detected: 47 queries to `comments` (expected 1). Add `.includes(:comments)` to reduce to 1 query." Makes severity immediately obvious.

- [x] **Dev UI endpoint** — A tiny Rack endpoint (e.g., `/__and_one`) in development that shows all N+1s detected in the current server session with fix suggestions. Like a mini BetterErrors for N+1s.

- [x] **GitHub Actions / CI annotations** — When `GITHUB_ACTIONS` env var is set, output detections in `::warning file=...` format so they appear as annotations on the PR diff.

- [x] **Ignore by caller pattern** — In addition to `ignore_queries` (SQL patterns), support `ignore_callers` to suppress detections originating from specific paths: "ignore any N+1 from `app/views/admin/*`".

- [x] **`has_many :through` and polymorphic support** — Extend the association resolver to handle `has_many :through` join chains and polymorphic associations, which are common sources of confusing N+1s.

- [x] **`preload` vs `includes` vs `eager_load` recommendation** — Suggest the optimal loading strategy based on the query pattern (e.g., `eager_load` when there's a WHERE on the association).

## ✅ Lower Priority — Nice to Have (Completed)

- [x] **Structured JSON logging** — A JSON output mode for log aggregation services (Datadog, Splunk, etc.). Set `AndOne.json_logging = true`. Uses `JsonFormatter` which outputs structured JSON with event, table, fingerprint, query count, suggestion, and backtrace. Also provides `format_hashes` for integrations that accept Ruby hashes directly.

- [x] **Thread-safety audit for Puma** — Formal audit and stress test suite complete. Found and fixed a **critical cross-thread contamination bug** in `Detector#subscribe`: the `ActiveSupport::Notifications` callback closure captured `self`, causing SQL from one thread to be recorded in another thread's Detector. Fixed by checking `Thread.current[:and_one_detector].object_id` in the callback. Also added Mutex protection for lazy singletons (`aggregate`, `ignore_list`), `AssociationResolver.@table_model_cache`, and report output serialization. 14 concurrent stress tests verify isolation, atomicity, and correctness under Puma-like load.

- [x] **Rails console integration** — Auto-scan in `rails console` sessions and print warnings inline. Activated automatically by the Railtie in development, or manually via `AndOne::Console.activate!`. Hooks into IRB (via `Context#evaluate` prepend) and Pry (via `:after_eval` hook) to cycle scans between commands.

- [x] **Configurable per-environment thresholds** — Different `min_n_queries` for dev vs test. Configure via `AndOne.env_thresholds = { "development" => 3, "test" => 2 }`. Falls back to global `min_n_queries` when no env-specific threshold is set. Supports both string and symbol keys.
