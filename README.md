# 🏀 AndOne

Find repeated ActiveRecord queries in Rails, investigate likely N+1s, and catch query regressions in tests. No external service required.

AndOne reports query counts, observed SQL time, call sites, and qualified fix suggestions. **Repeated SQL is evidence, not proof of an association N+1**: findings distinguish suspected association loading, identical reads, aggregates, and generic repetition.

## Installation

```ruby
# Gemfile
group :development, :test do
  gem "and_one"
end
```

Requires **Ruby 3.2+ and Rails components 7.0+**, using mutually compatible versions. Rails installs request and job hooks automatically:

| Environment | Default behavior |
|---|---|
| Development | Log findings, show in-page notices, and enable `/__and_one` |
| Test | Raise `AndOne::NPlus1Error` on every scan with findings |
| Production | Disabled if loaded; the Gemfile group above excludes it |

ActiveJob is supported across backends; direct Sidekiq jobs are hooked when Sidekiq is loaded at Railtie setup. Nested hooks reuse the existing scan. Development Rails consoles are scanned automatically.

Standalone scripts can use `AndOne.scan` with ActiveRecord; arbitrary database clients and other ORMs are not supported. See [standalone setup and tested versions](docs/usage.md#ruby-and-orm-support).

## What you get

- **Actionable investigation:** candidate `.includes()`/`.preload()` advice for simple association record loading; separate guidance for counts, existence checks, scalar queries, and duplicate reads.
- **Location hints:** the query origin and a heuristic caller to inspect—not a proven relation-construction site.
- **Measured impact:** exact eligible query counts and observed SQL notification time, not estimated savings.
- **Development dashboard:** browse `/__and_one`; sort retained findings by cumulative SQL time, occurrences, or executed query count.
- **Test helpers:** repeated-query matchers, physical query budgets, and input-growth assertions for Minitest and RSpec.
- **Reporting:** text or JSON logs, callbacks, GitHub Actions warning annotations, and first-occurrence deduplication.
- **Private, bounded samples:** SQL literals redacted by default; bind values never retained.

Toasts appear at **top-right** on eligible buffered HTML responses. Streaming, compressed, download, and non-HTML responses are left untouched. Under CSP, a script-free `<details>` notice replaces the styled toast. [UI details](docs/usage.md#development-ui).

## Finding classification

| Kind | Confidence | Meaning |
|---|---|---|
| `suspected_association_n_plus_one` | `candidate` | Varying values in simple record reads with qualified equality/IN predicates |
| `duplicate_identical_read` | `observed` | Identical lexical SQL/value signatures in non-aggregate reads |
| `repeated_aggregate` | `observed` | Repeated COUNT, SUM/AVG/MIN/MAX, or EXISTS-style projection |
| `generic_repetition` | `unknown` | Unsupported, missing, scalar, or complex evidence |

Classification uses bounded, per-scan HMAC signatures when value evidence is available; it never evaluates lazy bind callbacks. Intentional batching can still produce findings, and identical reads are not necessarily safe to cache. **Thresholds, ignores, test matchers, and `NPlus1Error` apply to all finding kinds.**

Association suggestions are candidates to verify, not automatic fixes. Ambiguous associations or complex SQL may receive only general guidance. `includes` alone does not fix association `.count` queries. See [classification evidence](docs/capture.md#classification-evidence) and [recommendation limits](docs/usage.md#recommendation-limits).

## Test query behavior

### Minitest

```ruby
class PostsTest < ActiveSupport::TestCase
  include AndOne::MinitestHelper

  test "preloads comments" do
    assert_no_n_plus_one do
      Post.preload(:comments).each { |post| post.comments.to_a }
    end
  end
end
```

### RSpec

```ruby
require "and_one/rspec"

RSpec.describe Post do
  it "preloads comments" do
    expect {
      Post.preload(:comments).each { |post| post.comments.to_a }
    }.not_to cause_n_plus_one
  end
end
```

These matchers respect ignores and `enabled`, but do not log, invoke callbacks, change deduplication, or raise `NPlus1Error`. Put them **around** requests/jobs, not inside an already active scan.

### Query budgets and growth

```ruby
# Prepare sufficient records and warm schema/connection caches first.
small = -> { Post.limit(2).preload(:comments).each { |p| p.comments.to_a } }
large = -> { Post.limit(20).preload(:comments).each { |p| p.comments.to_a } }

# Minitest
assert_query_budget(max: 2, &large)
assert_query_growth(small: small, large: large, max_growth: 0)

# RSpec
expect(&large).to stay_within_query_budget(2)
expect(small: small, large: large).to stay_within_query_growth(0)
```

Budgets count non-cached synchronous SQL notifications, including writes and transactions, but not schema events. Growth is `large.count - small.count`, not a ratio. Each workload runs once; AndOne does not create data, warm up, or clear caches. These measurements remain active when detection is disabled/paused and do not suppress normal scan enforcement. [Full test-helper semantics](docs/usage.md#test-matchers).

## Configuration

Configure in `config/initializers/and_one.rb`, before scanning:

```ruby
AndOne.configure do |config|
  config.min_n_queries = 2                  # default repetition threshold
  config.env_thresholds = { development: 3, test: 2 }
  config.raise_on_detect = Rails.env.test?  # Rails default
  config.dev_toast_position = :top_right    # default; or :top_left/:bottom_right/:bottom_left
  config.capture_mode = :redacted           # default; :raw is for trusted local debugging only

  # Optional: share aggregate findings across cooperating processes.
  # config.aggregate_store = :file          # default: bounded process-local memory

  # Rails development/test defaults to a session-scoped logfile.
  # config.logfile = nil                    # disable file output
  # config.logfile_format = :json           # default: :text
  # config.json_logging = true              # JSON console/logger output
end
```

Explicit initializer settings are preserved. Configure only between scans, not while requests/jobs are running. See the [configuration reference](docs/usage.md#configuration) for callbacks, custom paths, access guards, service lifecycle, and output failure behavior.

### Ignore accepted findings

Create `.and_one_ignore` in your application root:

```text
gem:devise
path:app/views/admin/*
query:schema_migrations
fingerprint:a1b2c3d4e5f6
```

Fingerprints ignore a query shape at **all locations/connections**; `issue_id` distinguishes location-specific findings. Query rules inspect original SQL, including occurrences beyond retained samples. [Ignore rules](docs/usage.md#ignoring-n1s) · [Fingerprint compatibility and migration](docs/sql-fingerprints.md).

### Storage and deduplication

The aggregate retains at most **100 issues**, evicting the least recently observed. Logs, annotations, and callbacks report only new retained issues; later occurrences update counts and costs. Evicted issues can be reported again. Every violating scan still raises when enforcement is enabled.

```ruby
AndOne.aggregate.summary    # formatted retained findings
AndOne.aggregate.detections # entries keyed by issue_id
AndOne.aggregate.reset!     # clear aggregate only
AndOne.reset_session!       # also flush and truncate the configured logfile
```

Memory storage is process-local and disappears on exit. File storage shares findings under `tmp/and_one/sessions`; the default development session persists across restarts, while independent test boots use isolated IDs. Set `AND_ONE_SESSION` before boot to select a shared session. Quiesce writers before resets. [Storage, cleanup, and upgrade notes](docs/storage.md).

## Capture privacy and dashboard access

SQL samples are **redacted before retention** by default. Each finding retains at most 5 samples × 2,048 bytes and 20 stack frames × 256 bytes, plus exact counts and cost summaries. `Detection#queries` is a sample, not the full query history.

Redaction is lexical, **not complete anonymization**: identifiers, filenames, and method names can remain visible. Raw mode can expose SQL literals and absolute paths; changing modes cannot revoke previously returned output or logs. Do not expose findings publicly or assume they are safe for production capture.

The dashboard defaults to direct loopback peers (`127.0.0.1`/`::1`) and sends `Cache-Control: no-store`. A local reverse proxy can make remote clients appear local. Secure the proxy or configure `dashboard_access_guard` using server-verified authentication. [Privacy and access configuration](docs/usage.md#capture-privacy-and-dashboard-access).

## Capture coverage and limits

- Scans capture synchronous ActiveRecord SQL in the **current fiber**. Child threads/fibers need their own scans; async-tagged SQL is excluded.
- Request scanning ends when the application returns its response. Lazy/streaming response-body SQL is outside that scan.
- Detection excludes cached queries and schema events. Costs describe eligible executed reads, not total request time or database-server CPU time.
- Samples and aggregate history are bounded, but distinct groups per scan and incoming SQL size are not. Parsing work and total scan memory are not strictly bounded.
- Block scans clean up on exceptions and nonlocal exits; nested scans reuse the outer scope. Use `AndOne.pause { ... }` to exclude known work.

## Documentation

- [Usage reference](docs/usage.md): output example, jobs, matchers, manual scans, configuration, privacy, and logging
- [Capture and measured costs](docs/capture.md): execution boundaries, private signatures, metrics, and benchmarks
- [Storage and sessions](docs/storage.md): sharing, retention, failures, resets, and migration
- [SQL fingerprints](docs/sql-fingerprints.md): eligibility, identity, supported syntax, and limitations
- [Compatibility](docs/compatibility.md): tested Ruby/Rails/adapters, accuracy corpus, and local test commands
- [Marketing site](site/README.md): local preview and GitHub Pages deployment

## License

[MIT](LICENSE.txt).
