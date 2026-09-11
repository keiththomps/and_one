# Aggregate storage and session lifecycle

## Defaults and sharing

The aggregate defaults to **bounded, process-local memory**, including in Rails.
No aggregate directory is created until file storage is actually used. Memory
history disappears on exit; forked workers inherit a snapshot, not shared counts.
To share counts and dashboard findings across a server, console, and job workers:

```ruby
AndOne.configure do |config|
  config.aggregate_store = :file
end
```

The file store and Rails development/test default logfile use
`<application root>/tmp/and_one/sessions/<session key>/`. Outside Rails, the
application root is the working directory. The key hashes the environment and
session ID; it is an isolation key, not a security boundary.

- Environment is Rails.env, then RAILS_ENV/RACK_ENV, then development.
- Development uses a stable `default` ID. Independently booting a console,
  runner, or worker joins the same findings without deleting anything.
- Test uses a random ID allocated when AndOne is loaded. Independent test boots
  are isolated; preloaded/forked workers inherit the same ID.
- Set **`AND_ONE_SESSION=ci-run-123` before boot** on every cooperating process
  to share an independent test run or select a fresh development session. Use a
  unique value per CI run, not per worker. Environment remains part of the key,
  even with an explicit ID. Do not change session environment variables live.

Rails development/test default `logfile` is `:session` (resolve its actual path
with `AndOne.logfile`). Standalone applications still default to no logfile.
`logfile = nil` or `false` disables it. Production remains disabled by default.
There are no destructive boot actions, timers, or automatic shutdown resets.

An explicit `aggregate_path` selects file storage at that **exact directory**,
regardless of `aggregate_store`. An explicit logfile string also uses that exact
path. These overrides deliberately bypass automatic session/environment
isolation: the application owns their naming, retention, and sharing policy.
Set `aggregate_path = nil` and `aggregate_store = :memory` to return to memory.
Configure services only between scans, with other writers stopped.

## Reset and cleanup ownership

No booting process owns the right to erase another process's findings. Reset is
an explicit operator action:

```ruby
AndOne.aggregate.reset! # only the currently configured aggregate
AndOne.reset_session!   # flush pending logfile output, reset aggregate, truncate logfile
AndOne.session.cleanup!(older_than: 7 * 86_400, limit: 100)
```

Stop/quiesce cooperating writers before resetting both sinks. Reset operations
are individually locked, not one atomic transaction across aggregate and log;
a running scan can repopulate findings afterward. Reset never deletes other
session directories. Custom paths are reset as explicitly configured.

Cleanup is opt-in maintenance. Each call examines at most `limit` directory
entries; repeated calls on the same Session instance continue through the
registry. It only removes stale, inactive session directories, not custom paths.
Age is based on the latest directory, aggregate, logfile, or lease modification.
Live processes hold shared leases (also inherited across fork); cleanup requires
an exclusive nonblocking lease. A registry lock coordinates joining and cleanup.
No multi-host/network-filesystem locking guarantees are made. Sessions are not
cleaned automatically, so schedule maintenance if using many test-run IDs.
Logfiles within a long-lived active session still need operator rotation/reset.

## Retention, cost, and failure policy

The public `record`, `detections`, `size`, `empty?`, `summary`, and `reset!` API is
preserved. `record_many(detections)` returns the new findings and commits the
entire scan in **one store transaction**. Stores implement `transaction` and
`reset!`; the Aggregate facade owns serialization, limits, and failure policy.

Both stores retain at most **100 unique issues**, evicting the least recently
observed issue. Evicted issues can be reported again; counts are totals only for
the retained history, not lifetime totals. Each retained first occurrence holds:

- at most 5 SQL samples, each at most 2,048 UTF-8 bytes;
- at most 20 backtrace frames, each at most 256 UTF-8 bytes;
- bounded adapter/connection labels, original count, and stable identities;
- constant-space query cost summaries for the first occurrence and all retained
  occurrences (count, timed count, total/min/max milliseconds, coverage).

[Cost metrics](capture.md#observed-finding-costs) survive persistence reloads;
missing historical metrics remain unknown and are not extrapolated.

Truncation does not recompute the original fingerprint or issue ID. Detection
thresholds, scan results, and ignores operate on the original capture, before
aggregate sample limiting. Historical valid documents are trimmed on access.

The file store reads at most **4 MiB + 1 byte**, rejects larger documents, and
never commits a document exceeding 4 MiB (including JSON escaping). It locks,
reads, and atomically replaces a single local JSON file per scan. Work is bounded
by the retained history, but this is still an O(retained entries) rewrite, not a
high-throughput database. Atomic rename prevents partial documents; there is no
fsync/power-loss durability guarantee. New aggregate/lock/log files use 0600;
new session/store directories use 0700. Existing permissions are not changed.

**SQL samples are redacted by default, but are not completely anonymous.**
Identifiers and application filenames can remain visible; opt-in raw capture can
retain secrets. Historical samples are sanitized when read in redacted mode,
but old logs/backups are not revoked. Do not expose findings to untrusted users.
See [capture privacy and dashboard access](usage.md#capture-privacy-and-dashboard-access).

By default, filesystem errors, corrupt/invalid JSON, oversized documents, and
failed writes produce a stderr diagnostic at most once per minute per Aggregate
instance, showing only the exception class. They do not fail application work
or suppress configured N+1 enforcement. A failed update treats every finding as
new for output; duplicates may be emitted and counts for that scan are lost.
Failed reads return an empty snapshot. Corrupt documents are **not silently
replaced**: fix the underlying problem, or explicitly `aggregate.reset!` to
recover. Interrupted temporary writes are removed on ordinary exceptions; an
abrupt process kill may leave a bounded `.tmp` file, overwritten on the next
write. There is no unbounded retry queue or invisible in-memory fallback.

`config.storage_strict = true` propagates storage errors instead (useful for
storage debugging/tests; a storage exception can precede N+1 enforcement).
Direct `Aggregate.new(path: ..., strict: true)` supports the same policy.

## Upgrade notes

Previous versions used `tmp/and_one/aggregate.json`, `log/and_one.log`, and
reset/truncated them on boot. They are no longer touched by defaults. Archive or
remove those old files explicitly. To keep the previous aggregate location,
configure `aggregate_path` explicitly; valid historical entries retain their
identities but are subject to the new bounds. To keep the old logfile location,
configure it explicitly, accepting that it is no longer isolated by session.

## Reproducible growth benchmark

Run `bundle exec ruby bench/aggregate_storage.rb`. It seeds 10, 100, and 1,000
unique historical findings, then measures 20 scans of 10 findings. Example on
Ruby 4.0.6, local filesystem (seconds vary; no wall-clock CI assertions):

```text
store,history,retained,bytes,20_scans_seconds
memory,10,10,n/a,0.0101
memory,100,100,n/a,0.0871
memory,1000,100,n/a,0.0851
file,10,10,3462,0.0404
file,100,100,34693,0.1242
file,1000,100,34912,0.1246
```

Retained entries and rewrite size plateau at the limit. Regression tests assert
bounds, transaction counts, process-safe counts, independent Rails boot/fork
lifecycles, malformed data preservation/reset, permission/open failures, and
interrupted writes, rather than timing thresholds.
