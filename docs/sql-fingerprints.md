# SQL fingerprints

`AndOne::Fingerprint.generate(sql, adapter: nil)` returns a normalized SQL shape. `Detection#fingerprint` hashes that shape and its table name for query-shape grouping and `fingerprint:` ignore rules. The detector and detection identity both pass their adapter metadata to the normalizer.

## Read-event eligibility and connection attribution

The detector accepts case-insensitive `SELECT` and `WITH [RECURSIVE]` statements whose CTE bodies and final statement are reads. CTE column lists, multiple CTEs, nested read CTEs, and `AS [NOT] MATERIALIZED` are supported. Ordinary leading comments and a single trailing semicolon are allowed. Literals and comments containing `SELECT` cannot turn a write into a read.

Eligibility is deliberately conservative, not a full parser: batches, `EXPLAIN`, opaque tokens (including executable comments and optimizer hints), data-modifying CTEs, and unquoted `INSERT`, `UPDATE`, `DELETE`, `MERGE`, `REPLACE`, `CREATE`, `ALTER`, `DROP`, or `INTO` anywhere are excluded. This also excludes `SELECT FOR UPDATE` and reads using these words as unquoted identifiers. Function side effects cannot be inferred. Existing lexer dialect limits below still apply. `SCHEMA` and cached notifications never contribute to detection counts; configured query ignores still apply.

Adapter metadata comes from the notification's `connection.pool.db_config`, never a checkout of `ActiveRecord::Base`. `connection_id` is a SHA-256 digest of the configuration environment/name, adapter, host, port, database, role, and shard (when available). Credentials and URLs are not retained in this identity. Logical database contexts are isolated during stack grouping, which uses ordered `(path, line)` tuples. Missing/unsupported connection metadata yields adapter `unknown` and a nil connection identity; such events cannot be distinguished by database. Async context propagation is not provided.

## Query-shape versus issue identity

`Detection#fingerprint` remains the existing 12-character broad ignore key. `Detection#issue_id` is a separate 24-character digest of that fingerprint, normalized application origin, adapter, and connection identity. Bind/literal values and outer request stacks do not create new issue identities; different origin lines or connection contexts do. Source-line changes may create a new issue. With no application origin, findings share an unknown-location identity within their shape/context.

Origins use root-relative paths (Rails root, or the working directory for standalone usage), without Ruby method labels. For external paths, conventional `app/`, `lib/`, `test/`, or `spec/` suffixes are retained; otherwise only the basename is used. External files with the same basename can therefore collide. `normalized_origin` exposes this portable call site; raw backtraces remain unchanged.

Aggregate entries are keyed by **issue ID**, not fingerprint. Both identities and connection metadata are persisted and shown in JSON; text, dashboard, and logfile output also preserve distinct issues. Fingerprint ignore rules continue to suppress the shape at **all** locations/connections. Use existing `path:` rules for path-specific suppression; there is no `issue_id:` ignore syntax.

Existing shape-keyed aggregate entries are rekeyed using their retained location on read and written in the new format on the next record. Previously discarded locations cannot be recovered. Old entries lack connection identity and may appear separately from new attributed findings; reset the aggregate once when upgrading for a clean session. Existing logfile content is not rewritten. This identity migration does **not** change normalization-version-2 fingerprints or require regenerating version-2 ignore rules.

## Normalization version 2

Version 2 scans SQL into tokens before normalizing it:

- SQL words are lowercased; quoted identifiers retain their exact case, quoting, and content. Quoted and unquoted identifiers are deliberately not assumed equivalent.
- Numbers (including decimal/exponent and common hexadecimal/binary forms), string literals, booleans, and bind placeholders become `?`.
- PostgreSQL `$1` parameters, dollar-quoted strings with ASCII tags, and `E'...'` escapes are recognized.
- SQLite `?NNN`, `:name`, `@name`, and `$name` parameters, bracket identifiers, and blob literals are recognized with the SQLite adapter.
- MySQL/Trilogy backslash-escaped strings, double-quoted strings, backtick identifiers, and `#` comments are recognized with those adapters. MySQL `--` starts a comment only when followed by whitespace or the end of input.
- Doubled quote escapes are handled inside strings and identifiers. Comment-looking text inside either is never processed as a comment.
- Ordinary comments are removed between tokens, never by concatenating surrounding words. Nested block comments are recognized. Executable comments (`/*! ... */`) and optimizer hints (`/*+ ... */`) are retained verbatim rather than silently discarded.
- Whitespace between tokens is canonicalized to one space. Whitespace inside quoted identifiers remains significant.
- Scalar `IN` lists containing only normalized values/parameters collapse to `( ? )`. Subqueries, row tuples, and lists containing expressions do not.
- `NULL`, operators, `LIMIT`/`OFFSET` clauses, and the shape of `VALUES` rows are preserved rather than conflated with different query structures.
- Unterminated quotes/comments are retained as opaque text, not silently erased.

For example:

```ruby
AndOne::Fingerprint.generate(
  'SELECT * FROM posts WHERE id IN ($1, $2)',
  adapter: "postgresql"
)
# => "select * from posts where id in ( ? )"
```

The normalizer does not execute SQL and does not change application queries.

## Compatibility and ignore migration

Version 2 changes normalized output and therefore **can change existing detection fingerprints**, including many ordinary queries because token spacing and quoted identifiers are now preserved differently. `NORMALIZATION_VERSION` is `2`.

When upgrading:

1. Reset stale aggregate data with `AndOne.aggregate.reset!` once for the intended shared session, not concurrently from each worker.
2. Reproduce previously ignored findings, inspect them, and replace old `fingerprint:` entries with newly reported IDs. Temporarily remove an old rule if necessary while validating the replacement.
3. Existing `gem:`, `path:`, and `query:` rules retain their existing behavior; they do not use normalized fingerprints.

Legacy fingerprints are **not** silently accepted as aliases: the old normalizer could conflate distinct queries, so carrying those identities forward would preserve incorrect suppressions. Pre-version-2 aggregate files do not migrate SQL normalization semantics; reset them rather than relying on the issue-key migration described above.

## Boundaries

This is a lexical normalizer, not a complete SQL parser or proof of semantic equivalence. It does not determine whether an N+1 exists, choose an execution plan, or act as a security-grade SQL redactor.

Adapter-free calls use a conservative default: standard doubled-quote strings, double-quoted/backtick identifiers, PostgreSQL dollar forms, `?` parameters, and `--` comments. Pass the actual adapter for dialect-sensitive syntax such as MySQL `#` comments versus PostgreSQL `#` operators.

Session-specific modes are not inferred. In particular, MySQL `ANSI_QUOTES`/`NO_BACKSLASH_ESCAPES`, PostgreSQL legacy `standard_conforming_strings=off`, and SQLite's double-quoted-string fallback are not modeled. Extended SQLite parameter syntax, arbitrary custom PostgreSQL operators, Unicode escape decoding, and vendor-specific grammar may remain distinct or unsupported. Unknown characters are retained as tokens. Do not rely on equivalent queries in different dialects receiving identical fingerprints.

Golden tests and deterministic randomized tests cover supported lexical behavior. Real multi-database compatibility coverage is tracked separately in issue #19.
