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

  Query:
    SELECT "comments".* FROM "comments" WHERE "comments"."post_id" = ?

  Call stack:
  → app/views/posts/index.html.erb:5
    app/controllers/posts_controller.rb:8

  💡 Fix:
    Add `.includes(:comments)` to your Post query
    at app/controllers/posts_controller.rb:8

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

The middleware is designed to **never interfere with error propagation**. If your app raises an exception during a request, AndOne silently stops scanning and re-raises the original exception with its backtrace completely intact.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
