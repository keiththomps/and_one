# 🏀 AndOne

Detect N+1 queries in Rails applications with zero configuration and actionable fix suggestions.

AndOne stays completely invisible until it detects an N+1 query — then it tells you exactly what's wrong and how to fix it. No external dependencies beyond Rails itself.

## Why not Prosopite / Bullet?

| | AndOne | Prosopite | Bullet |
|---|---|---|---|
| Zero config | ✅ Railtie auto-setup | ❌ Manual middleware + config | ❌ Manual config |
| Fix suggestions | ✅ Suggests exact `.includes()` | ❌ Just shows queries | ⚠️ Sometimes |
| Clean error handling | ✅ Never corrupts backtraces | ❌ Can mess up error output | ❌ |
| No external deps | ✅ Only Rails | ❌ Needs pg_query for Postgres | ❌ Has dependencies |
| Test integration | ✅ Auto-raises in test env | ⚠️ Manual setup | ⚠️ Manual setup |
| Background jobs | ✅ ActiveJob + Sidekiq | ⚠️ Sidekiq only (separate gem) | ❌ |
| Ignore file | ✅ `.and_one_ignore` with gem/path/query/fingerprint rules | ❌ | ❌ |
| Aggregate mode | ✅ Report each unique N+1 once per session | ❌ | ❌ |
| Test matchers | ✅ Minitest + RSpec | ❌ | ⚠️ |

## Installation

Add to your Gemfile:

```ruby
group :development, :test do
  gem "and_one"
end
```

That's it. AndOne automatically activates in development and test environments via a Railtie.

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

  Fix here (where to add .includes):
  ⇒ app/controllers/posts_controller.rb:8

  Call stack:
    app/views/posts/index.html.erb:5
    app/controllers/posts_controller.rb:8

  💡 Suggestion:
    Add `.includes(:comments)` to your Post query

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

# Ignore a specific detection by its fingerprint (shown in output)
fingerprint:a1b2c3d4e5f6
```

This is especially useful for **N+1s coming from gems** where you can't add `.includes()` to the source. Instead of littering your code with `AndOne.pause` blocks, add a `gem:` rule.

### When to use each rule type

| Rule | Use when... |
|---|---|
| `gem:devise` | A gem you depend on has an N+1 you can't fix |
| `path:app/views/admin/*` | An area of your app has known N+1s you've accepted |
| `query:some_table` | A specific query pattern should always be ignored |
| `fingerprint:abc123` | You want to silence one specific detection (shown in output) |

## Aggregate Mode

In development, the same N+1 can fire on every request, flooding your logs. Aggregate mode reports each unique pattern only once per server session:

```ruby
# config/initializers/and_one.rb
AndOne.aggregate_mode = true
```

You can check the session summary at any time:

```ruby
AndOne.aggregate.summary    # formatted string of all unique N+1s
AndOne.aggregate.size       # number of unique patterns
AndOne.aggregate.reset!     # clear and start fresh
```

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
require "and_one/rspec"

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

The matchers temporarily disable `raise_on_detect` internally, so they work correctly regardless of your global configuration.

## Behavior by Environment

- **Development**: Logs N+1 warnings to Rails logger and stderr
- **Test**: Raises `AndOne::NPlus1Error` so N+1s fail your test suite
- **Production**: Completely disabled (not even loaded)

## Configuration

AndOne works out of the box, but you can customize:

```ruby
# config/initializers/and_one.rb
AndOne.configure do |config|
  # Raise on detection (default: true in test, false in development)
  config.raise_on_detect = false

  # Minimum repeated queries to trigger (default: 2)
  config.min_n_queries = 3

  # Aggregate mode — only report each unique N+1 once per session
  config.aggregate_mode = true

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

  # Custom callback for integrations (logging services, etc.)
  config.notifications_callback = ->(detections, message) {
    # detections is an array of AndOne::Detection objects
    # message is the formatted string
    MyLogger.warn(message)
  }
end
```

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

## How It Works

1. **Subscribe** to `sql.active_record` notifications (built into Rails)
2. **Group** queries by call stack fingerprint
3. **Fingerprint** SQL to detect same-shape queries with different bind values
4. **Resolve** table names back to ActiveRecord models and associations
5. **Suggest** the exact `.includes()` call to fix the N+1
6. **Filter** against the `.and_one_ignore` file and aggregate tracker

The middleware is designed to **never interfere with error propagation**. If your app raises an exception during a request, AndOne silently stops scanning and re-raises the original exception with its backtrace completely intact.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
