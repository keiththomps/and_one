## [Unreleased]

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
