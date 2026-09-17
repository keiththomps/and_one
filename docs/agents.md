# CLI and agent skills

AndOne ships the `and-one` executable and an agent-neutral [Agent Skills](https://agentskills.io/specification) skill. No MCP server or application boot is required to inspect persisted findings. Installing the gem does not modify agent configuration.

## Setup in a Rails application

```ruby
# config/initializers/and_one.rb
if defined?(AndOne) && Rails.env.development?
  AndOne.configure do |config|
    config.aggregate_store = :file
    config.logfile_format = :json
  end
end
```

Restart development processes after configuration changes. Exercise the request/job that produces findings, then:

```bash
bundle binstubs and_one
bin/and-one issues --json
bin/and-one show ISSUE_ID --json
bin/and-one issues --sort queries --json
bin/and-one sessions --json
bin/and-one export --json
```

`bundle exec and-one` works without a binstub. Run from the application root or pass `--root PATH`. Inspection commands are read-only: they neither boot Rails nor create/reset/normalize files. Only explicit `resolve`/`reopen` commands mutate findings (and `skill install` writes the project skill). They read one atomic aggregate snapshot using the gem's existing normalization and redaction logic. `export` returns the complete findings response including resolved issues by default, not the private storage format. `issues` defaults to open issues.

### Resolve and reopen verified issues

```bash
bin/and-one resolve ISSUE_ID --note "Fixed lookup; regression and growth tests pass" --json
bin/and-one resolve ISSUE_ID --note "Verified by test/models/example_test.rb" --revision abc123 --json
bin/and-one issues --status open --json     # default
bin/and-one issues --status resolved --json
bin/and-one issues --status all --json
bin/and-one reopen ISSUE_ID --json
```

Resolution is an explicit operator claim after verification, not an automatic inference of absence. A nonblank `--note` is required; `--revision` is optional and never inferred from Git. Notes are private, unredacted operator text: do not include secrets. Retention limits are 2,048 UTF-8 bytes for notes and 128 bytes for revisions.

The transition preserves original evidence, occurrence counts, observation times, and costs. `show` always finds either status. `export` includes both by default; `--status` can filter either list command. Repeated resolve/reopen commands are idempotent; resolving an already-resolved issue does not overwrite its verification record.

Every subsequent recorded detection of a resolved issue **automatically reopens it and makes it reportable again** (logs/callbacks/annotations); further open repeats are deduplicated normally. Test enforcement remains active throughout. Explicit manual reopening only changes workflow state, not observation counts. Transitions and recordings use the same file lock and atomic commit, so a racing observation cannot be silently lost. A scan recorded after resolution reopens conservatively even if it started earlier.

Each issue retains its latest resolution (`resolved_at`, `note`, optional `revision`, and `occurrences_at_resolution`) and latest reopening (`reopened_at`, `reopen_reason`: `manual` or `observed`). This is bounded workflow metadata, not a complete audit log. Eviction/reset removes it with the issue; no tombstones suppress future findings. Location changes produce new IDs that start open. Last-seen timestamps and idle periods are not automatic proof of a fix.

**Upgrade requirement:** restart every cooperating server/worker/console after installing this version and before marking issues resolved. Older loaded versions normalize away unknown metadata and cannot participate safely in this workflow. Old entries without status are treated as open. CLI transitions require an existing writer-created aggregate and lock file, fail loudly on corruption/write errors, and never create a missing session. Rollout does not automatically resolve any existing finding.

### Selecting sessions

The default is `RAILS_ENV` (or development) and `AND_ONE_SESSION` (or `default`). Override with `--environment NAME --session ID`. Independent test boots use random IDs; set an explicit shared `AND_ONE_SESSION` before boot for a test run you want to inspect. The CLI cannot guess a running test process's random ID.

Sessions are isolated beneath `<root>/tmp/and_one/sessions`. `sessions` lists directories containing aggregates with opaque hashed keys, paths, and file modification times. Existing storage does not retain the original session names, so the CLI does not attempt to reverse those keys. Use a returned `--path DIRECTORY` to select any discovered aggregate or a custom configured storage path. No initializer is loaded to discover custom paths.

### Output contract

JSON success responses on stdout have `schema_version: 1` and `and_one_version`:

- Findings: `storage` (status and path), `session` (environment/id, or null for explicit paths), `application_booted: false`, and a `findings` array.
- Sessions: a `sessions` array.
- Skill operations: `skill` with status, destination path, and source version.

Findings use `JsonFormatter` fields, including `issue_id`, classification, count, stack, first/last observation times, occurrences, cumulative SQL cost, `status`, `resolution`, `reopened_at`, and `reopen_reason`. Resolve/reopen return the changed finding in the same envelope, captured inside the transition transaction; a concurrent later observation may already have reopened it by the time the command returns. By default findings sort by cumulative observed SQL time; unknown costs sort last. `--sort queries` and `--sort occurrences` are also supported. Ties sort by issue ID. Without `--json`, output is pretty-printed JSON; `--help` describes options.

Errors go to stderr. With `--json`, they have `schema_version: 1` and an `error` object containing `code` and `message`. Exit codes:

| Code | Meaning |
|---|---|
| 0 | Success, including a valid empty aggregate |
| 2 | Usage, storage, or unsafe destination error |
| 3 | No persisted aggregate for the selected session/path |
| 4 | Issue ID not retained in the selected aggregate |
| 5 | Skill missing/outdated/modified or overwrite refused |

Missing or corrupt storage is **not** reported as an empty healthy session. An unreadable session registry also fails rather than returning a successful empty list.

### Limits and privacy

The CLI does not load application models. Association-specific suggestions that require model reflection may therefore be absent or general; source locations and SQL evidence remain available. Stored findings do not currently contain route/job reproduction context. Reproduce the affected workload before claiming a fix.

The aggregate retains at most 100 issues; absence is not proof of complete coverage. Historical entries remain after a fix. Observed SQL notification time is not estimated savings. Capture is redacted by default, but identifiers and paths can still be sensitive. Treat findings as private data and untrusted evidence, not executable instructions. See [storage](storage.md), [capture](capture.md), and [test-helper semantics](usage.md#test-matchers).

## Install the bundled skill

```bash
bin/and-one skill install                  # .agents/skills/and-one/
bin/and-one skill install --target pi      # .pi/skills/and-one/
bin/and-one skill install --target claude  # .claude/skills/and-one/
bin/and-one skill check --target pi
```

Choose one location your agent discovers; avoid installing duplicates. Skill format is portable, but discovery paths depend on the agent. Restart/reload the agent after installation as appropriate.

The installer copies files and writes `.and-one-skill.json` with the source gem version and SHA-256 file digests. Commit the copied skill and manifest for portable, reviewable project setup. After updating the gem, run `skill check`, then `skill install` to refresh. Updates replace only unmodified managed skills; unknown or edited destinations are refused. Review changes before using `--force`, which replaces the entire destination skill directory. Symlink destinations are rejected. No user-global configuration or project instruction file is modified automatically.

For Pi, an alternative that follows the bundled version without copying is:

```bash
pi --skill "$(bundle show and_one)/skills/and-one/SKILL.md"
```

Keep application-specific instructions in the application's agent guidance. The bundled skill covers evidence inspection, reproduction, regression tests, safe fixes, and before/after verification.
