## [Unreleased]

## [0.2.0] - 2026-03-02

### Added

- **Dev toast notifications** — When an N+1 is detected during a request, a toast notification is injected into the bottom-right corner of the page showing which tables were affected with a link to the `/__and_one` dashboard. Enabled by default in development. Auto-dismisses after 8 seconds; hover to keep open. Only appears on HTML 200 responses. Disable with `AndOne.dev_toast = false`.
- New `dev_toast` configuration option
- "Development UI" section in README documenting both the toast and dashboard features

## [0.1.0] - 2026-02-27

- Initial release
