# Compatibility and accuracy checks

## CI coverage

The compatibility Gemfile selects an explicit Rails minor series (latest compatible
patch/dependencies at resolution time). Its generated lockfile is separate from
`Gemfile.lock`; neither CI nor the commands below updates the default lockfile.
This is a bounded representative matrix, not a promise that every Ruby/Rails/adapter
combination works:

| Ruby | Rails | Checks |
| --- | --- | --- |
| 3.2 | 7.0 | Full suite + RuboCop on SQLite; corpus on PostgreSQL 16 and MySQL 8.0 |
| 3.3 | 7.2 | Full suite + RuboCop on SQLite |
| 4.0 | 8.1 | Full suite + RuboCop on SQLite; corpus on PostgreSQL 16 and MySQL 8.0 |

Rails 7.0 uses sqlite3 1.x; Rails 7 uses JSON <3 because its encoder passes the
removed `quirks_mode` option. These constraints are for the test stack, not extra
runtime dependencies of AndOne. Use upstream-compatible dependency versions in
applications too. The earlier ModuleLength offense has already been resolved by
existing configuration/reporting extractions; the matrix runs lint without disabling it.

The fast default remains `bundle exec rake`. To reproduce a matrix job, select its
Ruby first (for example `mise use ruby@3.2`, or your preferred version manager):

```sh
export BUNDLE_GEMFILE=gemfiles/compatibility.gemfile
export RAILS_VERSION=7.0.0 # or 7.2.0 / 8.1.0 with the corresponding Ruby
bundle install
bundle exec rake
```

Service-backed runs require libpq/MySQL client development libraries and a
**disposable** database. The helper drops/recreates tables; never point this at an
application database. For example, start PostgreSQL 16 or MySQL 8.0 using the service
configuration in `.github/workflows/main.yml`, then:

```sh
export BUNDLE_GEMFILE=gemfiles/compatibility.gemfile RAILS_VERSION=8.1.0
export DB=postgresql # or mysql2
export DATABASE_URL='postgresql://and_one:and_one@127.0.0.1:5432/and_one_test?prepared_statements=true'
# MySQL: mysql2://and_one:and_one@127.0.0.1:3306/and_one_test?prepared_statements=true
bundle install
bundle exec ruby -Itest test/test_accuracy_corpus.rb
```

Run only the portable corpus against service databases: some existing unit/stress
tests deliberately replace the connection with SQLite. Unset `DATABASE_URL`, `DB`,
`BUNDLE_GEMFILE`, and `RAILS_VERSION` when returning to default development. Generated
`gemfiles/*.lock` files are ignored; remove them to reproduce fresh CI resolution,
or retain them to repeat an exact local dependency set.

## Labeled accuracy corpus

`test/fixtures/accuracy_corpus.rb` defines 17 small scenarios and a reusable schema.
Each label distinguishes workload truth from the detector's **current observed
behavior**. Failures name the scenario, expected actionability, and limitations;
there is deliberately no aggregate accuracy/marketing score.

- Basic has-many/belongs-to, custom keys in both directions, has-one, and scoped
  loading: candidate association advice. Both suggested `includes` and `preload`
  are executed; ordered result IDs must be identical, physical queries must drop
  to two, and repeated-query findings must disappear. Scoped fixtures include both
  matching and non-matching rows.
- Two same-table associations, polymorphic loading, and through loading: repeated
  queries detected, but exact association advice is explicitly unsupported.
- COUNT, EXISTS, and scalar reads: operation-specific guidance, not record-preload
  advice.
- Identical lookups and intentional batching: known false positives for the
  association-N+1 interpretation. Tests record today's behavior, not endorse it.
- Query-cache hits and preloaded loading: intentional non-N+1 examples without
  findings. Cached queries do not count as physical database work.
- One child load below the repetition threshold: an explicit known false negative
  of threshold-based detection, rather than a claim that the workload scales.

A separate integration check asserts prepared statements are enabled, observes real
adapter bind metadata on repeated association queries, and checks preload removes
the finding. Schema creation, fixture writes, and model metadata warmup are outside
both scan and measurement. Each measurement begins uncached; only the cache scenario
explicitly enables caching within that scope. Counts exclude cache hits, schema
notifications, and transaction control. No timing assertions or arbitrary workload
reruns are hidden in public APIs: before/after executions are explicit test cases.

These are recommendation/actionability labels, not new public classification
fields. Bind-based classification remains a separate issue (#21). The corpus is
not exhaustive SQL coverage and does not establish causal association attribution.
