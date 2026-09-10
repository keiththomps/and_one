# 🏀 AndOne

Detect N+1 queries in Rails applications with zero configuration and actionable fix suggestions.

AndOne stays completely invisible until it detects an N+1 query — then it points to repeated queries and suggests what to investigate. No external dependencies beyond Rails itself.

## Features

- **Zero configuration** — Railtie auto-setup in development and test
- **Qualified fix suggestions** — suggests candidate `.includes()`/`.preload()` calls for basic association record loading, with separate guidance for counts and scalar queries
- **Location hints** — shows the origin and a heuristic caller location to investigate (not the proven relation-construction site)
- **Clean error handling** — never corrupts backtraces or interferes with exception propagation
- **No external dependencies** — only Rails itself
- **Auto-raises in test** — N+1s fail your test suite by default
- **Background job support** — ActiveJob (`around_perform`) and Sidekiq server middleware, with double-scan protection
- **Ignore file** — `.and_one_ignore` with `gem:`, `path:`, `query:`, and `fingerprint:` rules
- **Bounded deduplication** — occurrence counts with in-memory storage by default and opt-in shared, session-scoped file storage
- **Test matchers** — Minitest (`assert_no_n_plus_one`) and RSpec (`expect { }.not_to cause_n_plus_one`)
- **Dev toast notifications** — in-page toast on every page that triggers an N+1, with a link to the dashboard
- **Dev UI dashboard** — browse `/__and_one` in development; rank findings by observed SQL time, occurrences, or executed query count
- **Rails console integration** — auto-scans in `rails console` and prints warnings inline
- **Structured JSON logging** — JSON output mode for Datadog, Splunk, and other log aggregation services
- **Per-environment thresholds** — different `min_n_queries` for development vs test
- **GitHub Actions annotations** — N+1s appear as warning annotations on PR diffs
- **`strict_loading` suggestions** — also suggests model-level prevention as an alternative
- **Conservative association resolution** — handles unambiguous `belongs_to`, `has_one`, and `has_many`; abstains on complex or ambiguous SQL
- **Isolated capture** — one SQL subscriber, fiber-local scans, and bounded representative query samples; verified with concurrent stress tests

## Recommendation limits

SQL alone does not prove which Ruby association was called. Association advice uses currently loaded models and qualified equality/`IN` predicates in plain, single-table SELECTs. Both foreign keys and `belongs_to` target primary keys (including custom single-column keys) are considered. Multiple matching associations/models, through associations, polymorphic associations, joins, aliases, CTEs, composite keys, and other complex SQL may receive only non-actionable guidance. Models and reflections are not cached: late-loaded models and Rails-reloaded classes are considered on the next resolution without retaining stale misses/classes.

For basic record loading, try the suggested `includes` or `preload` on the parent relation and verify equivalent scopes/results and fewer queries. Filters or AND/OR tokens do **not** establish that a JOIN is faster. COUNT receives counter-cache/grouped-count guidance: `includes` alone does not eliminate association `.count` queries; `.size` can reuse an already loaded association when loading all its records is acceptable. Existence and scalar lookups receive batching guidance rather than an invented association fix. `strict_loading` hints apply to lazy record loading, not count/existence queries.

The possible fix location is a **heuristic** caller frame, not necessarily where the relation was constructed. Text, dashboard, and GitHub annotations label it accordingly; JSON retains `fix_location` and adds `fix_location_confidence: "heuristic"`. JSON suggestions include `operation`, `association_type`, and `confidence` (`candidate` or `guidance_only`); guidance-only entries may have a null association/loading strategy.

## Installation

Add to your Gemfile:

```ruby
group :development, :test do
  gem "and_one"
end
```

That's it. AndOne automatically activates in development and test environments via a Railtie.

## Ruby and ORM support

AndOne requires Ruby 3.2+ and ActiveRecord/ActiveSupport/Railties 7.0+ (choose versions compatible with your Ruby). Rails applications get automatic request/job integration. Outside a Rails application, “plain Ruby” support means **ActiveRecord SQL instrumentation**, not arbitrary database clients or other ORMs such as Sequel. Railties remains a runtime dependency; RSpec is optional and only needed for `and_one/rspec`. No public RBS signatures are currently shipped.

CI exercises Ruby/Rails 3.2/7.0, 3.3/7.2, and 4.0/8.1 on SQLite, plus the oldest/current boundaries on PostgreSQL 16 and MySQL 8.0. A 17-scenario labeled corpus checks recommendation accuracy, known limitations, and before/after result equivalence and physical query counts. See [the support matrix and local reproduction commands](docs/compatibility.md).

A standalone script can use:

```ruby
require "and_one"       # loads its ActiveRecord and Railtie dependencies itself
require "sqlite3"       # install your chosen database adapter separately

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: "app.sqlite3")
# Define/load your ActiveRecord models, e.g. Post has_many :comments.
AndOne.configure do |config|
  config.enabled = true
  config.raise_on_detect = false
end

detections = AndOne.scan do
  Post.all.each { |post| post.comments.to_a }
end
puts "Detected #{detections.size} repeated-query patterns"
```

Standalone scans are enabled by default and do not raise unless configured. They do not install request/job hooks or Rails environment defaults until a Rails application boots. Normal scans keep bounded findings in memory by default; set `aggregate_store = :file` before the first scan for process sharing. `require "and_one"` is safe before or after loading Rails.

## Capture coverage and limits

Scans capture synchronous ActiveRecord SQL in the **current fiber**. Child fibers/threads do not inherit scans; start independent scans inside them if needed. Async-tagged SQL is excluded because Rails may publish worker notifications later in an unrelated consumer's scan. Synchronous `load_async` fallback is captured normally. Lazy response-body SQL is outside request scan coverage.

One process-level subscriber routes events to the active context. Each repeated shape/location retains its first five SQL samples plus an exact total count: `Detection#queries` is a sample, while `Detection#count` includes all eligible occurrences. Query-ignore rules still inspect every occurrence. Unique groups and individual SQL sizes are not capped.

Findings expose `query_cost` timing summaries from monotonic SQL notifications; aggregate entries roll them up across repeated occurrences. Cache hits and async work are excluded, and historical missing costs remain unknown. These are observed costs, not estimated savings. JSON rollups are available through `AndOne::JsonFormatter.new.format_aggregate(AndOne.aggregate.detections)`.

See [capture boundaries, measured costs, retention, and benchmark commands](docs/capture.md) for details.

## What You'll See

When an N+1 is detected, you get output like:

```
──────────────────────────────────────────────────────────────────────────
 🏀 And One! 1 N+1 query detected
──────────────────────────────────────────────────────────────────────────

  1) 9x repeated query on `comments`
     fingerprint: a1b2c3d4e5f6

  Query:
    SELECT "comments".* FROM "comments" WHERE "comments"."post_id" = ?

  Origin (where the N+1 is triggered):
  → app/views/posts/index.html.erb:5

  Possible fix location (heuristic; inspect the caller):
  ⇒ app/controllers/posts_controller.rb:8

  Call stack:
    app/views/posts/index.html.erb:5
    app/controllers/posts_controller.rb:8

  💡 Suggestion:
    If this is Post#comments record loading, try `.includes(:comments)` or `.preload(:comments)` on the parent query; verify scopes and results.

  To ignore, add to .and_one_ignore:
    fingerprint:a1b2c3d4e5f6

──────────────────────────────────────────────────────────────────────────
```

## Background Jobs

### ActiveJob (any backend)

Automatically hooked via `around_perform`. Works with **every** ActiveJob backend:
Sidekiq, GoodJob, SolidQueue, Delayed Job, Resque, and anything else that uses ActiveJob.

No configuration needed — the Railtie handles it.

### Sidekiq (direct usage)

For jobs that use Sidekiq directly (bypassing ActiveJob), AndOne installs a server middleware automatically when Sidekiq is detected.

If you need manual installation:

```ruby
Sidekiq.configure_server do |config|
  config.server_middleware do |chain|
    chain.add AndOne::SidekiqMiddleware
  end
end
```

When both hooks are active (ActiveJob job running through Sidekiq), the Sidekiq middleware detects the existing scan from ActiveJobHook and passes through — no double-scanning.

## Ignoring N+1s

### The `.and_one_ignore` file

Create a `.and_one_ignore` file in your project root to permanently silence known N+1s. Supports four rule types:

```bash
# Ignore N+1s originating from a specific gem
# (matches against raw backtrace paths, e.g. /gems/devise-4.9.0/)
gem:devise
gem:administrate

# Ignore N+1s whose call stack matches a path pattern (supports * globs)
path:app/views/admin/*
path:lib/legacy/**

# Ignore N+1s matching a SQL pattern
query:schema_migrations
query:pg_catalog

# Ignore a query shape at all locations by its fingerprint (shown in output)
fingerprint:a1b2c3d4e5f6
```

This is especially useful for **N+1s coming from gems** where you can't add `.includes()` to the source. Instead of littering your code with `AndOne.pause` blocks, add a `gem:` rule.

### When to use each rule type

| Rule | Use when... |
|---|---|
| `gem:devise` | A gem you depend on has an N+1 you can't fix |
| `path:app/views/admin/*` | An area of your app has known N+1s you've accepted |
| `query:some_table` | A specific query pattern should always be ignored |
| `fingerprint:abc123` | You want to silence a query shape at all locations/connections |

## Deduplication

In development, the same N+1 can fire on every request, flooding your logs. AndOne automatically deduplicates — each unique issue (query shape + application origin + connection context) is reported only once while retained in the aggregate (per process by default, or across cooperating processes with file storage). Subsequent occurrences at that location are silently counted; the same SQL shape at a different location remains visible as a separate issue.

Deduplication applies to logs, GitHub annotations, logfile output, and `notifications_callback` (which receives only newly observed findings). Scan results still contain every non-ignored finding in that scan. When `raise_on_detect` is enabled, **every violating scan raises**, even if the pattern was already reported by another scan. Test matchers do not report or consume first-occurrence deduplication.

You can check the session summary at any time:

```ruby
AndOne.aggregate.summary    # formatted string of all unique N+1s
AndOne.aggregate.size       # number of unique issues
AndOne.aggregate.detections # { issue_id => Entry }; entry.detection.fingerprint is the broad ignore key
AndOne.aggregate.reset!     # clear and start fresh
```

Output includes a location-aware `issue_id` alongside the unchanged broad `fingerprint` ignore key. Stored entries retain both identities. Old shape-keyed entries are migrated using their retained location; reset once on upgrade to avoid duplicate historical entries without connection metadata. See [identity and eligibility limits](docs/sql-fingerprints.md#query-shape-versus-issue-identity).

SQL normalization version 2 can change detection fingerprints. When upgrading, reset stale aggregate data and regenerate affected `fingerprint:` ignore entries. See [SQL fingerprints](docs/sql-fingerprints.md) for supported syntax, dialect limitations, and migration steps.

## Development UI

### In-page toast notifications

When an N+1 is detected during a request, AndOne injects a small toast notification into the bottom-right corner of the page. The toast shows which tables were affected and links to the full dashboard for details.

This is enabled by default in development — no configuration needed. The toast auto-dismisses after 8 seconds, but hovering over it keeps it open.

To change the position or disable it:

```ruby
# config/initializers/and_one.rb
AndOne.dev_toast_position = :bottom_right  # :top_right (default), :top_left, :bottom_right, :bottom_left
AndOne.dev_toast = false                   # disable entirely
```

The toast only transforms complete `text/html` responses with status 200 and a Rack `to_ary` body (including ordinary Rails renders). HEAD, API, redirect, error, encoded/compressed, streaming, file/download, and partial responses are left untouched. Place AndOne inside compression middleware to inject before compression. Transformed responses lose Content-Length and validators/digests; untouched content keeps its metadata. Rack bodies own cleanup in `to_ary`, including on conversion errors; AndOne does not enumerate arbitrary bodies or close converted bodies a second time.

With a Content-Security-Policy header (including report-only) or CSP meta tag, the toast becomes an unstyled, script-free native `<details>` notice with a dashboard link. It does not auto-dismiss or use the position setting, and never requires `unsafe-inline` or changes your policy.

**SQL coverage:** scanning ends when the application returns its Rack response, before lazy body enumeration. Queries executed by streaming/lazy bodies are not captured by this middleware; use an explicit scan within that workload if needed.

### Dashboard

Browse `/__and_one` in development for a full overview of every unique N+1 detected in the current server session. The dashboard shows the query, origin, fix location, and suggested `.includes()` call for each detection. Access defaults to loopback peers (`127.0.0.1` or `::1`); missing/remote peer addresses receive 403. See [capture privacy and dashboard access](#capture-privacy-and-dashboard-access) for shared-development setups.

Both features work together: the toast gives you immediate feedback on the page you're looking at, and the dashboard link takes you to the full picture.

## Test Matchers

### Minitest

```ruby
class PostsControllerTest < ActionDispatch::IntegrationTest
  include AndOne::MinitestHelper

  test "index does not cause N+1 queries" do
    assert_no_n_plus_one do
      get posts_path
    end
  end

  test "known N+1 is documented" do
    detections = assert_n_plus_one do
      get legacy_report_path
    end
    assert_equal "comments", detections.first.table_name
  end
end
```

### RSpec

```ruby
# In spec_helper.rb or rails_helper.rb
require "and_one/rspec" # loads RSpec core and registers the helper, in either require order

# Then in your specs
RSpec.describe "Posts" do
  it "loads posts efficiently" do
    expect {
      Post.includes(:comments).each { |p| p.comments.to_a }
    }.not_to cause_n_plus_one
  end

  it "has a known N+1" do
    expect {
      Post.all.each { |p| p.comments.to_a }
    }.to cause_n_plus_one
  end
end
```

N+1 matchers capture a non-reporting scan: they never change global configuration, invoke callbacks, write findings, or raise `NPlus1Error`. Other concurrent scans retain their configured reporting and enforcement. Ignores and `enabled = false` still apply (disabled matchers execute the block but see no detections).

Starting an N+1 matcher inside an already active scan raises `ArgumentError` **before executing its block**. Put the matcher around the request/job or scan instead; ordinary nested request/job scans still pass through to the matcher's scope. Both successful Minitest helpers count one assertion.

### Physical query budgets and input growth

These explicit measurements count database work independently of repeated-shape detection:

```ruby
# Create fixtures and warm schema/connection caches BEFORE these scopes.
# Workloads must build fresh relations/records, not reuse loaded associations.
small = -> { Post.limit(2).preload(:comments).each { |p| p.comments.to_a } }
large = -> { Post.limit(20).preload(:comments).each { |p| p.comments.to_a } }

# Minitest (include AndOne::MinitestHelper)
result = assert_query_budget(max: 2, &large)
result.count         # executed query count
result.cached_count  # cache hits, excluded from the budget
result.locations     # up to five query call sites, no SQL/bind values
result = assert_query_growth(small: small, large: large, max_growth: 0)
result.growth        # large.count - small.count

# RSpec (require "and_one/rspec")
expect(&large).to stay_within_query_budget(2)
expect(small: small, large: large).to stay_within_query_growth(0)
```

Limits are non-negative integers and inclusive. Growth measures the **absolute increase** in query count, not a ratio or timing: a bound of zero requires constant or decreasing counts. Each supplied workload runs exactly once, small before large; the library never creates fixtures, warms up, clears caches, or silently reruns your block. Choose genuinely different input sizes and prepare sufficient data yourself. Setup performed inside a workload is counted.

Counts include non-cached `sql.active_record` events, including reads, writes, and transaction statements, but exclude `SCHEMA` events and empty SQL. Cache hits are counted separately. Existing cache state is preserved: for cold-query regression tests wrap the assertions in `ActiveRecord::Base.uncached`; for warm-cache tests warm up explicitly outside measurement. These are notification counts, not network round trips (e.g. a multi-statement event counts once).

Captures are fiber-local; nested captures are inclusive for the parent and independent for the child. Exceptions and nonlocal exits restore the parent scope. Child fibers, threads, and asynchronous queries are not included. Unlike N+1 matchers, these explicit counts remain active when AndOne is disabled/paused and do not apply ignores or detection thresholds. They neither start an N+1 scan nor change reporting settings: existing or nested application scans retain their normal enforcement and can still raise `NPlus1Error`. Failures show small/large counts and bounded query locations without retaining SQL or bind values. Query budgets complement, rather than prove the absence of, N+1 behavior.

## Behavior by Environment

- **Development**: Logs N+1 warnings to Rails logger and stderr
- **Test**: Raises `AndOne::NPlus1Error` so N+1s fail your test suite
- **Production**: Disabled by default if loaded; the recommended Gemfile group excludes it

## Capture privacy and dashboard access

The default `AndOne.capture_mode = :redacted` replaces SQL string/numeric/boolean literals, bind placeholders, comments (including hints), and opaque/unterminated tokens with `?` **before retaining samples**. Bind values and lazy bind callbacks are not retained or evaluated. This affects returned detections, callbacks, exceptions, text/JSON output, logs, aggregate storage, and the dashboard—not SQL execution. Fingerprints and query-ignore matching use original SQL before redaction, including occurrences beyond the sample limit. Caller/path/gem ignores inspect the original stack before capture limits.

Each detection retains at most **5 SQL samples × 2,048 bytes** and **20 frames × 256 bytes** in either mode. Frames prioritize application code while preserving stack order. Default frames remove absolute application prefixes; external paths become portable suffixes/filenames. `raw_caller_strings` now means policy-limited strings before optional backtrace cleaning; `caller_locations` contains bounded snapshots with `path`, `absolute_path`, `lineno`, and `to_s` accessors.

Redaction is lexical, not complete anonymization: schema/table/column identifiers and application filenames/method names remain visible. Adapter-specific quoting matters; SQLite/unknown-adapter ambiguous double-quoted values are conservatively masked, which can hide unqualified column names too. Backslashes in quoted tokens conservatively mask the rest of the sample because session-dependent escaping rules can be ambiguous. Avoid embedding secrets in identifiers or using unsupported vendor literal syntax. Do not expose findings publicly or enable production capture on the assumption that redaction removes all sensitive information.

For temporary local debugging only, opt in explicitly **before scanning**:

```ruby
AndOne.capture_mode = :raw # WARNING: SQL literals and absolute paths can contain credentials/PII
```

Raw mode remains bounded and does not capture binds. Changing modes cannot revoke already returned detections, callbacks, or written logs. Existing aggregate samples are sanitized when read under redacted mode; old logs/backups must be removed separately. Newly created aggregate, lock, and log files use mode `0600` (aggregate directories use `0700`); existing files' permissions are not automatically changed.

The dashboard returns `Cache-Control: no-store`. It trusts only the direct Rack `REMOTE_ADDR`, not forwarding headers. A local reverse proxy can make remote clients appear local: secure the proxy or supply an explicit guard. For shared development, integrate with trusted authentication middleware **before** DevUI:

```ruby
AndOne.dashboard_access_guard = ->(env) { env["my_app.authenticated_developer"] == true }
```

A configured callable replaces the loopback check; false/nil or an exception denies access. Only use server-verified identity, not an arbitrary client header. This is an access hook, not an authentication framework.

## Configuration

AndOne works out of the box, but you can customize:

```ruby
# config/initializers/and_one.rb
AndOne.configure do |config|
  # Raise on detection (default: true in test, false in development)
  config.raise_on_detect = false

  # Minimum repeated queries to trigger (default: 2)
  config.min_n_queries = 3

  # In-page toast notifications (default: true in development)
  config.dev_toast = true

  # Toast position (default: :top_right)
  # Options: :top_right, :top_left, :bottom_right, :bottom_left
  config.dev_toast_position = :top_right

  # Opt in to process sharing (default: bounded in-memory storage)
  config.aggregate_store = :file

  # Optional exact custom directory; also opts into file storage.
  # Custom paths bypass automatic environment/session isolation.
  # config.aggregate_path = Rails.root.join("tmp", "my_findings").to_s

  # Raise storage errors instead of diagnosing them (default: false)
  config.storage_strict = false

  # Path to ignore file (default: Rails.root/.and_one_ignore)
  config.ignore_file_path = Rails.root.join(".and_one_ignore").to_s

  # Allow specific patterns (won't flag these call stacks)
  config.allow_stack_paths = [
    /admin_controller/,
    /some_legacy_code/
  ]

  # Ignore specific query patterns
  config.ignore_queries = [
    /pg_catalog/,
    /schema_migrations/
  ]

  # Custom backtrace cleaner
  config.backtrace_cleaner = Rails.backtrace_cleaner

  # Rails dev/test default: findings.log in the environment/session directory.
  # A custom path bypasses session isolation; nil disables file output.
  config.logfile = :session

  # Logfile format: :text or :json (default: :text)
  config.logfile_format = :text

  # Custom callback for integrations (logging services, etc.)
  config.notifications_callback = ->(detections, message) {
    # detections is an array of AndOne::Detection objects
    # message is the formatted string
    MyLogger.warn(message)
  }
end
```

### Configuration lifecycle

Rails defaults are applied before `config/initializers`, without overwriting explicitly assigned settings (including `logfile = nil` or `false`). Service setup and middleware registration happen after those initializers. Development/test enable scanning and a session-scoped logfile under `Rails.root/tmp/and_one/sessions`; only test raises by default. Production is disabled by default, but can be explicitly enabled.

Configure before scanning. Between scans, changing `aggregate_path`, `aggregate_store`, `storage_strict`, or `ignore_file_path` rebuilds the corresponding cached service on next access. Changing `logfile` or `logfile_format` first flushes the old writer, then replaces it; a flush failure raises and rejects that configuration change. Do not reconfigure while requests/jobs are running. Other settings are read by subsequent scans/reports. Boot never resets the aggregate or truncates the logfile. See [storage and session lifecycle](docs/storage.md) for defaults, explicit resets, bounded cleanup, limits, and migration.

### Logfile delivery and failures

New, ignore-filtered findings are flushed synchronously after each reporting scan, so they are visible before process exit. First-occurrence deduplication still applies: later occurrences update the aggregate, not the logfile. Buffered failures are retried on the next scan containing findings (even already-known findings), or explicitly with `AndOne.logfile_writer&.flush!`. Rails also attempts a final flush at exit. No timer threads are created.

Format/open/write failures retain pending entries. Cooperating processes use file locks; failed partial appends are rolled back when the filesystem permits. The retry buffer holds at most 1,000 unique findings; overflow rejects the new batch with a rate-limited diagnostic during reporting, preserving previously accepted entries. Newly rejected findings are not automatically redelivered because aggregate deduplication has already occurred. This is best-effort delivery, not crash durability or exactly-once delivery; shutdown, rollback failure, or buffer exhaustion can lose findings.

Callbacks run outside output locks and may reenter scanning. Callback and output `StandardError`s are diagnosed on stderr at most once per minute and do not fail application work or suppress configured `NPlus1Error` enforcement. `NPlus1Error` itself is always propagated, including from a nested callback scan. Callbacks are not retried. Explicit writer `record`/`flush!` calls still raise on failure. Aggregate persistence failures also default to non-disruptive, rate-limited diagnostics; `storage_strict = true` opts into propagation. See [storage policy](docs/storage.md).

## Manual Scanning

You can also scan specific blocks:

```ruby
# In a test
detections = AndOne.scan do
  posts = Post.all
  posts.each { |p| p.comments.to_a }
end

assert_empty detections

# Pause/resume within a scan
AndOne.scan do
  # This is scanned
  posts.each { |p| p.comments.to_a }

  AndOne.pause do
    # This is NOT scanned
    legacy_code_with_known_n_plus_ones
  end

  # Scanning resumes automatically after the pause block
end
```

Block scans release their own detector on every exit, including exceptions, `return`, `break`, and `throw`. Only normal completion analyzes and reports findings. Nested scans pass through to the block without taking ownership of the outer scan. Nested pause blocks restore the previous pause state.

For manual `AndOne.scan` / `AndOne.finish` pairs, the caller must invoke `finish` when done (including on exceptional paths, typically via `ensure`). `finish` releases the detector even if analysis or reporting raises; calling it with no active scan returns `[]`. Prefer the block API when application errors should bypass reporting.

## How It Works

1. **Subscribe** to `sql.active_record` notifications (built into Rails)
2. **Group** eligible reads by ordered call stack and emitting connection context
3. **Fingerprint** SQL to detect same-shape queries with different bind values
4. **Resolve** table names back to ActiveRecord models and associations
5. **Suggest** a candidate preload for basic record loading or operation-specific investigation guidance
6. **Filter** against the `.and_one_ignore` file and aggregate tracker

The middleware is designed to **never interfere with error propagation**. If your app raises an exception during a request, AndOne silently stops scanning and re-raises the original exception with its backtrace completely intact.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
