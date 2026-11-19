# PgTextsearch

Minimal ActiveRecord wrapper for [pg_textsearch](https://github.com/timescale/pg_textsearch) BM25 indexes.

Follows the [`neighbor`](https://github.com/ankane/neighbor) philosophy: **wrap only the awkward SQL bits** (`<@>` operator, `to_bm25query()`, and `WITH (...)` index options) and return standard `ActiveRecord::Relation` objects so `.where`, `.limit`, `.includes`, `.select`, `.group`, `.joins` all work unchanged.

## Requirements

- PostgreSQL 17+ with `pg_textsearch` extension
- `shared_preload_libraries = 'pg_textsearch'` in `postgresql.conf`
- Ruby 3.2+
- ActiveRecord 7.0+

## Installation

```bash
bundle add pg_textsearch
```

## Setup

1. Add to `postgresql.conf`:
   ```
   shared_preload_libraries = 'pg_textsearch'
   ```

2. Restart PostgreSQL

3. Enable the extension in your database:
   ```sql
   CREATE EXTENSION pg_textsearch;
   ```

---

## Core API

```ruby
# Model declaration
class Product < ApplicationRecord
  has_bm25 :name, index: :products_name_idx
  has_bm25 :description, index: :products_desc_idx
  has_bm25 "coalesce(name, '') || ' ' || coalesce(description, '')", index: :products_all_idx
end

# Basic search (adds BM25 filter + ORDER BY)
Product.bm25_search(:name, "wireless headphones", index: :products_name_idx).limit(10)

# With explicit index (required for prepared statements/partial indexes)
Product.bm25_search(:description, "noise cancelling", index: :products_desc_idx).limit(10)

# Compose with standard ActiveRecord
Product
  .where(active: true, category: "electronics")
  .bm25_search(:name, "wireless headphones", index: :products_name_idx)
  .limit(20)

# Expose BM25 score (raw negative value, more negative = better match)
Product.bm25_search(:name, "headphones", index: :products_name_idx, select_score: true).limit(5)
# product.bm25_score  # => -2.34

# Score only (no ORDER BY), still filtered by default
Product.bm25_search(:name, "headphones", index: :products_name_idx, select_score_only: true)

# Predicate for manual WHERE composition
Product.where(Product.bm25_match(:name, "headphones", index: :products_name_idx))
```

---

## Query Options

All options can be passed per-query or as defaults in `has_bm25`:

```ruby
class Product < ApplicationRecord
  has_bm25 :search_text, index: :products_idx,
    unaccent: true,        # default: accent-insensitive
    prefix: true           # default: prefix matching
end

# Per-query overrides
Product.bm25_search(:search_text, "headphones", index: :products_idx,
  prefix: true,           # "headphones*" - autocomplete style
  any_word: true,         # "headphones OR wireless" (default: AND)
  negation: true,         # "headphones !sony" - exclude terms
  unaccent: true,         # "cafe" matches "café"
  fuzzy: {threshold: 0.3},# typo tolerance via pg_trgm
  synonyms: true,         # "pop" matches "soda" (requires thesaurus dict)
  highlight: true,        # adds pg_search_highlight attribute
  ranked_by: ":bm25 + 0.1 * products.popularity",
  order_within_rank: "products.updated_at DESC"
)
```

### Option Reference

| Option | Type | Description |
|--------|------|-------------|
| `index` | Symbol/String | Explicit index name (recommended; required for prepared statements/partial indexes) |
| `select_score` | Boolean/Symbol | Expose BM25 score as `bm25_score` or custom alias |
| `select_score_only` | Boolean/Symbol | Expose score without adding `ORDER BY` |
| `filter` | Boolean | Add BM25 match filter (`... <@> ... < 0`). Default: `true` |
| `where` | Boolean | Apply extra fuzzy/pg_trgm WHERE conditions when `fuzzy` is used. Default: `true` |
| `prefix` | Boolean | Append `:*` to each word for prefix matching |
| `any_word` | Boolean | Match ANY term (OR) instead of ALL (AND) |
| `negation` | Boolean | Support `!term` exclusion syntax |
| `unaccent` | Boolean | Accent-insensitive search (requires `unaccent` extension) |
| `fuzzy` | Hash/Boolean | Typo tolerance via `pg_trgm` similarity (`threshold: 0.3`) |
| `synonyms` | Boolean | Use thesaurus dictionary (requires `dict_thesaurus` + thesaurus file) |
| `highlight` | Boolean/Hash | Add `pg_search_highlight` via `ts_headline` (`plainto_tsquery` for safe input) |
| `ranked_by` | String | Custom ranking expression; `:bm25` replaced with score SQL |
| `order_within_rank` | String | Tiebreaker ORDER BY (e.g., `updated_at DESC`) |

### Highlight Options

```ruby
highlight: {
  start_sel: "<mark>",      # default: "<b>"
  stop_sel: "</mark>",      # default: "</b>"
  max_words: 35,            # default: 35
  min_words: 15,            # default: 15
  short_word: 3,            # default: 3
  highlight_all: false,     # default: false
  max_fragments: 0,         # default: 0 (no fragmentation)
  fragment_delimiter: "..." # default: "..."
}
```

---

## Common Use Cases

### 1. E-commerce Product Search

```ruby
# Migration: multi-column search index with custom BM25 params
class AddProductSearchIndex < ActiveRecord::Migration[8.0]
  def change
    enable_extension "pg_textsearch"

    # Combined name + description + tags index
    execute <<~SQL
      CREATE INDEX products_search_idx ON products
      USING bm25 (
        (coalesce(name, '') || ' ' || coalesce(description, '') || ' ' || coalesce(tags, ''))
      )
      WITH (text_config = 'english', k1 = 1.5, b = 0.75);
    SQL

    # Partial index for active products only
    execute <<~SQL
      CREATE INDEX products_active_search_idx ON products
      USING bm25 (
        (coalesce(name, '') || ' ' || coalesce(description, ''))
      )
      WITH (text_config = 'english', k1 = 1.5, b = 0.75)
      WHERE active = true;
    SQL
  end
end

# Model
class Product < ApplicationRecord
  has_bm25 "coalesce(name, '') || ' ' || coalesce(description, '') || ' ' || coalesce(tags, '')",
    index: :products_search_idx
  has_bm25 :name, index: :products_active_search_idx  # partial index
end

# Search endpoint
def search
  scope = Product.where(active: true)

  scope = scope.where(category_id: params[:category]) if params[:category].present?
  scope = scope.where("price BETWEEN ? AND ?", params[:min_price], params[:max_price]) if params[:min_price]
  scope = scope.where(brand_id: params[:brand]) if params[:brand].present?

  results = scope.bm25_search(
    "coalesce(name, '') || ' ' || coalesce(description, '') || ' ' || coalesce(tags, '')",
    params[:q],
    index: :products_search_idx,
    select_score: true,
    prefix: true,
    unaccent: true
  ).limit(params[:limit] || 20)

  render json: results.as_json(methods: :bm25_score)
end
```

### 2. Faceted Search with Aggregates

```ruby
def search_with_facets
  base = Product.where(active: true)
                .bm25_search(:search_text, params[:q], index: :products_search_idx, select_score: true)

  # Results with score
  @products = base.limit(20)

  # Facets via standard ActiveRecord aggregations
  @facets = {
    categories: Product.where(active: true).group(:category).count,
    brands:     Product.where(active: true).group(:brand).count,
    price_ranges: Product.where(active: true).group(
      Arel.sql("CASE
        WHEN price < 50 THEN 'Under $50'
        WHEN price < 100 THEN '$50-$100'
        WHEN price < 200 THEN '$100-$200'
        ELSE '$200+'
      END")
    ).count,
    ratings: Product.where(active: true).group(:rating).count
  }
end
```

### 3. Related Products (Content-Based)

```ruby
class Product < ApplicationRecord
  # Find products with similar descriptions
  def related_products(limit: 5)
    return Product.none if description.blank?

    Product.where(active: true)
           .where.not(id: id)
           .bm25_search(:description, description, index: :products_desc_idx)
           .limit(limit)
  end

  # Find products sharing tags (using JSONB expression index)
  # Migration: CREATE INDEX products_tags_idx ON products USING bm25 ((tags)) WITH (text_config='simple');
  def related_by_tags(limit: 5)
    Product.where(active: true)
           .where.not(id: id)
           .bm25_search("tags", tags.to_json, index: :products_tags_idx)
           .limit(limit)
  end
end
```

### 4. Multilingual Search

```ruby
# Migration: one partial index per language
class AddMultilingualIndexes < ActiveRecord::Migration[8.0]
  def change
    enable_extension "pg_textsearch"

    execute <<~SQL
      CREATE INDEX products_en_idx ON products USING bm25 (
        (coalesce(name, '') || ' ' || coalesce(description, ''))
      ) WITH (text_config = 'english') WHERE locale = 'en';
    SQL

    execute <<~SQL
      CREATE INDEX products_de_idx ON products USING bm25 (
        (coalesce(name, '') || ' ' || coalesce(description, ''))
      ) WITH (text_config = 'german') WHERE locale = 'de';
    SQL

    execute <<~SQL
      CREATE INDEX products_fr_idx ON products USING bm25 (
        (coalesce(name, '') || ' ' || coalesce(description, ''))
      ) WITH (text_config = 'french') WHERE locale = 'fr';
    SQL
  end
end

class Product < ApplicationRecord
  has_bm25 :search_text, index: :products_en_idx  # default fallback
end

def search
  locale = params[:locale] || I18n.locale.to_s
  index_name = "products_#{locale}_idx".to_sym

  Product.where(locale: locale, active: true)
         .bm25_search(:search_text, params[:q], index: index_name)
         .limit(20)
end
```

### 5. Hybrid Search (BM25 + Vector)

```ruby
# Requires pgvector extension
# Simple linear combination of BM25 score + vector distance
def hybrid_search(query_text, query_embedding, limit: 10)
  bm25_sql = "search_text <@> to_bm25query(?, 'products_search_idx')"
  vector_sql = "embedding <=> ?"

  Product.where(active: true)
         .select("products.*, #{bm25_sql} AS bm25_score, #{vector_sql} AS vector_distance")
         .order(Arel.sql("#{bm25_sql} + #{vector_sql}"))
         .limit(limit)
end
```

```ruby
# RRF (Reciprocal Rank Fusion) using ActiveRecord CTE (Rails 6.1+)
def hybrid_search_rrf(query_text, query_embedding, limit: 10)
  k = 60  # RRF constant

  bm25_cte = Product.select(:id)
                    .select(Arel.sql("ROW_NUMBER() OVER (ORDER BY search_text <@> to_bm25query(?, 'products_search_idx')) AS rank"))
                    .where(active: true)
                    .limit(20)

  vec_cte = Product.select(:id)
                   .select(Arel.sql("ROW_NUMBER() OVER (ORDER BY embedding <=> ?) AS rank"))
                   .where(active: true)
                   .limit(20)

  Product.with(bm25: bm25_cte, vec: vec_cte)
         .select("products.*, COALESCE(1.0/(#{k}+b.rank),0) + COALESCE(1.0/(#{k}+v.rank),0) AS rrf_score")
         .joins("LEFT JOIN bm25 b ON b.id = products.id")
         .joins("LEFT JOIN vec v ON v.id = products.id")
         .where(active: true)
         .order("rrf_score DESC")
         .limit(limit)
end
```

### 6. Autocomplete / Prefix Search

```ruby
# Built-in prefix option
def autocomplete(query, limit: 10)
  Product.where(active: true)
         .bm25_search(:name, query, index: :products_name_idx, prefix: true)
         .limit(limit)
end
```

### 7. Search Analytics / Logging

```ruby
class SearchLog < ApplicationRecord
  def self.log(query, user_id, results_count, latency_ms)
    create!(query: query, user_id: user_id, results_count: results_count, latency_ms: latency_ms)
  end
end

def search
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  results = Product.where(active: true)
                   .bm25_search(:search_text, params[:q], index: :products_search_idx)
                   .limit(20)

  latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round
  SearchLog.log(params[:q], current_user&.id, results.size, latency_ms)

  render json: results
end
```

### 8. Admin: Index Maintenance Rake Tasks

```ruby
# lib/tasks/pg_textsearch.rake
namespace :pg_textsearch do
  desc "Check if indexes need compaction"
  task check_compaction: :environment do
    indexes = %w[products_search_idx products_name_idx products_desc_idx]
    indexes.each do |idx|
      needs = PgTextsearch::Maintenance.needs_compaction?(idx)
      levels = PgTextsearch::Maintenance.level_counts(idx)
      puts "#{idx}: needs_compaction=#{needs} levels=#{levels}"
    end
  end

  desc "Compact all indexes"
  task compact: :environment do
    indexes = %w[products_search_idx products_name_idx products_desc_idx]
    indexes.each do |idx|
      puts "Compacting #{idx}..."
      PgTextsearch::Maintenance.compact(idx)
    end
  end

  desc "Run one compaction step per index (safe for cron)"
  task compact_step: :environment do
    indexes = %w[products_search_idx products_name_idx products_desc_idx]
    indexes.each do |idx|
      ran = PgTextsearch::Maintenance.compact_step(idx)
      puts "#{idx}: #{ran ? 'ran step' : 'nothing to do'}"
    end
  end

  desc "Spill memtables to disk (after bulk load)"
  task spill: :environment do
    indexes = %w[products_search_idx products_name_idx products_desc_idx]
    indexes.each do |idx|
      pages = PgTextsearch::Maintenance.spill_index(idx)
      puts "#{idx}: spilled #{pages} pages"
    end
  end
end
```

```bash
# Run via cron (every 5 min)
*/5 * * * * cd /app && bundle exec rake pg_textsearch:compact_step

# After bulk import
bundle exec rake pg_textsearch:spill
```

---

## Optional Extensions

Enable these PostgreSQL extensions for advanced features:

```ruby
# Accent-insensitive search
PgTextsearch::Maintenance.enable_unaccent!
# Creates unaccent extension + IMMUTABLE wrapper function

# Fuzzy/prefix matching (pg_trgm)
PgTextsearch::Maintenance.enable_pg_trgm!
# Then use: fuzzy: {threshold: 0.3} in bm25_search

# Synonyms (thesaurus dictionary)
PgTextsearch::Maintenance.enable_thesaurus!('thesaurus_en', 'thesaurus_en')
# Requires thesaurus_en.ths file in $SHAREDIR/tsearch_data/
# Example thesaurus file content:
#   pop, soda, cola
#   headphones, earphones, cans
#   laptop, notebook
```

---

## Score Selection

By default, `bm25_search` adds a BM25 match filter and `ORDER BY`. Add `select_score: true` to also expose the raw negative BM25 score:

```ruby
products = Product.bm25_search(:search_text, "headphones", index: :products_search_idx, select_score: true).limit(5)
products.first.bm25_score  # => -2.34 (more negative = better match)
```

Custom alias:

```ruby
products = Product.bm25_search(:search_text, "query", index: :idx, select_score: :relevance)
products.first.relevance
```

Score without `ORDER BY`:

```ruby
products = Product.bm25_search(:search_text, "query", index: :idx, select_score_only: true)
```

Disable row filtering (ORDER BY-only ranking):

```ruby
products = Product.bm25_search(:search_text, "query", index: :idx, filter: false)
```

---

## Migrations & `schema.rb` Support

```ruby
class AddSearchIndexes < ActiveRecord::Migration[8.0]
  def change
    enable_extension "pg_textsearch"

    # Main search index with custom BM25 params
    add_index :products, :search_text,
      name: :products_search_idx,
      using: :bm25,
      with: { text_config: "english", k1: 1.5, b: 0.75 }

    # Partial index for active products
    add_index :products, :search_text,
      name: :products_active_idx,
      using: :bm25,
      where: "active = true",
      with: { text_config: "english", k1: 1.5, compaction: "background" }

    # Expression index for JSONB tags
    execute <<~SQL
      CREATE INDEX products_tags_idx ON products USING bm25 ((tags))
      WITH (text_config = 'simple');
    SQL
  end
end
```

The `with:` options are dumped to `schema.rb` automatically.

---

## Maintenance Helpers

For Rake tasks or background jobs:

```ruby
PgTextsearch::Maintenance.needs_compaction?(:products_search_idx)  # => true / false
PgTextsearch::Maintenance.compact(:products_search_idx)            # full compaction
PgTextsearch::Maintenance.compact_step(:products_search_idx)       # one pass (cron-safe)
PgTextsearch::Maintenance.spill_index(:products_search_idx)        # force memtable spill
PgTextsearch::Maintenance.level_counts(:products_search_idx)       # => [2, 1, 0, ...]

# Optional extension helpers
PgTextsearch::Maintenance.enable_unaccent!
PgTextsearch::Maintenance.enable_pg_trgm!
PgTextsearch::Maintenance.enable_thesaurus!('thesaurus_en', 'thesaurus_en')
```

---

## What's Intentionally Left Out

To keep the gem under ~300 lines and avoid fighting ActiveRecord:

- **No Boolean `tsquery` DSL** — Standard `.where("content @@ to_tsquery(?, ?)", "english", query)` is already concise.
- **No automatic score negation** — `pg_textsearch` returns negative BM25 scores for ascending index scans. Keep the raw value so `ORDER BY` behavior matches `EXPLAIN` output and Postgres docs.
- **No automatic `LIMIT` injection** — Let callers chain `.limit(n)` explicitly so they understand how Block-Max WAND and `pg_textsearch.default_limit` behave.
- **No `pg_durable` orchestration** — Treat `compaction: "background"` as a pass-through index option, not a gem-managed worker system.
- **No multi-search/global index** — Different architecture; use separate models + UNION if needed.
- **No automatic synonym expansion** — Requires manual thesaurus dictionary setup.

---

## License

MIT License. See LICENSE.txt.