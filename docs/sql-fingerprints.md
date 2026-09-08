# SQL fingerprints

`AndOne::Fingerprint.generate(sql, adapter: nil)` returns a normalized SQL shape. `Detection#fingerprint` hashes that shape and its table name for aggregation and `fingerprint:` ignore rules. The detector and detection identity both pass their adapter metadata to the normalizer.

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

Legacy fingerprints are **not** silently accepted as aliases: the old normalizer could conflate distinct queries, so carrying those identities forward would preserve incorrect suppressions. Existing aggregate files do not migrate identities automatically; without a reset they may show both old and new entries.

## Boundaries

This is a lexical normalizer, not a complete SQL parser or proof of semantic equivalence. It does not determine whether an N+1 exists, choose an execution plan, or act as a security-grade SQL redactor.

Adapter-free calls use a conservative default: standard doubled-quote strings, double-quoted/backtick identifiers, PostgreSQL dollar forms, `?` parameters, and `--` comments. Pass the actual adapter for dialect-sensitive syntax such as MySQL `#` comments versus PostgreSQL `#` operators.

Session-specific modes are not inferred. In particular, MySQL `ANSI_QUOTES`/`NO_BACKSLASH_ESCAPES`, PostgreSQL legacy `standard_conforming_strings=off`, and SQLite's double-quoted-string fallback are not modeled. Extended SQLite parameter syntax, arbitrary custom PostgreSQL operators, Unicode escape decoding, and vendor-specific grammar may remain distinct or unsupported. Unknown characters are retained as tokens. Do not rely on equivalent queries in different dialects receiving identical fingerprints.

Golden tests and deterministic randomized tests cover supported lexical behavior. Real multi-database compatibility coverage is tracked separately in issue #19.
