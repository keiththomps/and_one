## [Unreleased]

### Fixed

- Enforce `raise_on_detect` for every violating scan, independently of first-occurrence reporting and aggregate history (#2).
- Release owned scans on exceptions and nonlocal exits; preserve outer scans and nested pause state (#3).
- Tokenize SQL before fingerprint normalization, fixing PostgreSQL bind placeholders and comment characters inside quoted text (#4). Preserve quoted identifiers and structural distinctions.

### Changed

- **Fingerprint migration:** normalization version 2 can change detection IDs. Reset stale aggregate data and regenerate affected `fingerprint:` ignore rules. See [SQL fingerprints](docs/sql-fingerprints.md) for details and dialect limitations.

## [0.4.0] - 2026-03-05

### Fixed

- **Toast now respects ignore rules** — Previously, the dev toast showed all detected N+1s including ones filtered by `.and_one_ignore` or `ignore_callers`. The toast, dashboard, and log output now all show the same filtered set of detections. This also applies to the return value of `AndOne.scan { }` and `AndOne.finish`.

### Changed

- **Disk-based aggregate storage** — The aggregate now stores detections as JSON on disk (`tmp/and_one/` in Rails apps) instead of in-process memory. This means all Puma workers in a multi-process deployment share the same dashboard data. The aggregate is automatically reset on server boot. Configure a custom path with `AndOne.aggregate_path`.

### Added

- `AndOne.aggregate_path` configuration option for custom aggregate storage location
- `Detection` now supports construction from raw caller strings (for deserialization from disk)

## [0.3.1] - 2026-03-05

### Added

- **Configurable toast position** — `AndOne.dev_toast_position` accepts `:top_right` (default), `:top_left`, `:bottom_right`, or `:bottom_left`. The slide-in animation direction adjusts automatically to match.

## [0.3.0] - 2026-03-05

### Removed

- **`aggregate_mode` configuration option** — Deduplication and aggregate tracking are now always-on when AndOne is enabled. The dev toast and dashboard both depend on the aggregate, so having it off was a bug in disguise (detections would show in the toast but never appear on the dashboard). If you had `AndOne.aggregate_mode = true` in an initializer, simply remove the line.

### Fixed

- N+1 detections now always appear on the `/__and_one` dashboard. Previously, detections would show in the toast notification but not on the dashboard unless `aggregate_mode` was explicitly enabled.

## [0.2.0] - 2026-03-02

### Added

- **Dev toast notifications** — When an N+1 is detected during a request, a toast notification is injected into the bottom-right corner of the page showing which tables were affected with a link to the `/__and_one` dashboard. Enabled by default in development. Auto-dismisses after 8 seconds; hover to keep open. Only appears on HTML 200 responses. Disable with `AndOne.dev_toast = false`.
- New `dev_toast` configuration option
- "Development UI" section in README documenting both the toast and dashboard features

## [0.1.0] - 2026-02-27

- Initial release
