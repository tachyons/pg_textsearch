## [Unreleased]

## [0.1.6] - 2026-11-19

### Fixed
- **#22**: `prefix: true` filter now quotes/escapes tsquery lexemes in the `@@ to_tsquery(...)` path, preventing `PG::SyntaxError` for inputs containing tsquery operators or punctuation (e.g. `:`, `&`, parentheses).

## [0.1.5] - 2026-11-19

### Fixed
- **#1**: `prefix: true` now uses `@@ to_tsquery(...)` for BM25 search/match filtering so `:*` prefix expansion works at runtime (while keeping BM25 `<@>` ordering).
- **#20**: `bm25_match` now resolves expressions declared via `has_bm25` (`expression:` / aliased expression targets), matching `bm25_search` behavior.
- **#21**: `unaccent: true` now applies unaccent as a SQL expression in the `to_bm25query(...)` argument (not a quoted literal), so query-side accent normalization is effective.

## [0.1.4] - 2026-11-19

### Fixed
- **#1**: Verified and tested that `prefix: true` is applied to both WHERE filtering and ORDER BY in `bm25_search`.
- **#19**: `has_bm25 ... expression: true` now treats the target as the expression (instead of generating `true <@> ...`).

## [0.1.3] - 2026-11-19

### Added
- `filter:` option for `bm25_search` (default `true`) to add `WHERE ... <@> ... < 0` row filtering; set `filter: false` to keep ORDER BY-only behavior.
- `where:` option for `bm25_search` (default `true`) to control fuzzy/extra WHERE conditions.
- Expression index support: `has_bm25` accepts an expression string (e.g. JSONB/computed columns) as the target and stores per-target defaults.

### Fixed
- **#9**: `bm25_match` now takes `(target, query, ...)` and returns an Arel SQL predicate for use in `where(...)`.
- **#11**: Expression targets/indexes are handled correctly in search/match SQL generation.
- **#15**: `bm25_search` now filters rows by default instead of ranking the whole table.
- **#16**: `prefix: true` now works together with `any_word: true`.
- **#17**: Highlighting uses `plainto_tsquery` so tsquery operators/parentheses in user input no longer raise syntax errors.
- **#18**: `has_bm25` defaults are stored per target (no longer overwritten by later declarations).

## [0.1.2] - 2026-11-19

### Fixed
- Issue #9: `bm25_match` method references undefined `target` variable.
- Issue #11: Missing expression index support.

### Added
- Expression index support via `expression:` option in `has_bm25`.
- `bm25_match` now correctly accepts `target` as first parameter.

## [0.1.1] - 2026-11-19

### Fixed
- Issues #1-8 with tests.

## [0.1.0] - 2026-11-18

- Initial release
