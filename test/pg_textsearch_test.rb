# frozen_string_literal: true

require "active_record"
require "pg_textsearch"
require "minitest/autorun"

# Set up a minimal SQLite connection for SQL generation tests
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")

class Document < ActiveRecord::Base
  self.table_name = "documents"
  has_bm25 :content, index: :docs_idx
end

class DocumentWithDefaults < ActiveRecord::Base
  self.table_name = "documents"
  has_bm25 :content, index: :docs_idx, unaccent: true, prefix: true
end

class DocumentNoDefault < ActiveRecord::Base
  self.table_name = "documents"
end

ActiveRecord::Schema.define do
  create_table :documents do |t|
    t.text :content
    t.integer :category_id
  end
end

class PgTextsearchTest < Minitest::Test
  def test_bm25_search_with_explicit_index
    sql = Document.bm25_search(:content, "database system", index: :docs_idx).to_sql
    assert_match(/ORDER BY "?content"? <@> to_bm25query/, sql)
    assert_match(/'docs_idx'/, sql)
  end

  def test_bm25_search_with_has_bm25_declaration
    sql = Document.bm25_search(:content, "database system").to_sql
    assert_match(/ORDER BY "?content"? <@> to_bm25query/, sql)
    assert_match(/'docs_idx'/, sql)
  end

  def test_bm25_search_without_index_uses_implicit
    sql = DocumentNoDefault.bm25_search(:content, "database system", index: nil).to_sql
    assert_match(/ORDER BY "?content"? <@> to_bm25query\('database system'\)/, sql)
  end

  def test_bm25_search_with_select_score
    sql = Document.bm25_search(:content, "database system", index: :docs_idx, select_score: true).to_sql
    assert_match(/AS "?bm25_score"?/, sql)
  end

  def test_bm25_search_with_custom_score_alias
    sql = Document.bm25_search(:content, "database system", index: :docs_idx, select_score: :my_score).to_sql
    assert_match(/AS "?my_score"?/, sql)
  end

  def test_bm25_search_composes_with_where
    sql = Document.where(category_id: 1).bm25_search(:content, "database system", index: :docs_idx).to_sql
    assert_match(/WHERE .*category_id.*=.*1/, sql)
    assert_match(/ORDER BY "?content"? <@> to_bm25query/, sql)
  end

  def test_bm25_search_with_arel_expression
    arel = Arel.sql("(data->>'description')")
    sql = Document.bm25_search(arel, "network error", index: :events_expr_idx).to_sql
    assert_match(/ORDER BY \(data->>'description'\) <@> to_bm25query/, sql)
    assert_match(/'events_expr_idx'/, sql)
  end

  def test_bm25_search_with_raw_sql_string
    sql = Document.bm25_search("data->>'description'", "network error", index: :events_expr_idx).to_sql
    assert_match(/ORDER BY data->>'description' <@> to_bm25query/, sql)
  end

  # --- New Feature Tests ---

  def test_bm25_search_prefix
    sql = Document.bm25_search(:content, "database", index: :docs_idx, prefix: true).to_sql
    assert_match(/database:\*/, sql)
  end

  def test_bm25_search_any_word
    sql = Document.bm25_search(:content, "database system", index: :docs_idx, any_word: true).to_sql
    assert_match(/\|/, sql)
  end

  def test_bm25_search_negation
    sql = Document.bm25_search(:content, "database !system", index: :docs_idx, negation: true).to_sql
    assert_match(/!system/, sql)
  end

  def test_bm25_search_unaccent
    sql = DocumentWithDefaults.bm25_search(:content, "database", index: :docs_idx).to_sql
    assert_match(/unaccent/, sql)
  end

  def test_bm25_search_highlight
    sql = Document.bm25_search(:content, "database", index: :docs_idx, highlight: true).to_sql
    assert_match(/ts_headline/, sql)
    assert_match(/pg_search_highlight/, sql)
  end

  def test_bm25_search_highlight_custom_options
    sql = Document.bm25_search(
      :content, "database",
      index: :docs_idx,
      highlight: { start_sel: "<mark>", stop_sel: "</mark>", max_words: 50 }
    ).to_sql
    assert_match(/StartSel=<mark>/, sql)
    assert_match(%r{StopSel=</mark>}, sql)
    assert_match(/MaxWords=50/, sql)
  end

  def test_bm25_search_ranked_by
    sql = Document.bm25_search(
      :content, "database",
      index: :docs_idx,
      ranked_by: ":bm25 + 0.1 * products.popularity"
    ).to_sql
    assert_match(/products\.popularity/, sql)
  end

  def test_bm25_search_order_within_rank
    sql = Document.bm25_search(
      :content, "database",
      index: :docs_idx,
      order_within_rank: "products.updated_at DESC"
    ).to_sql
    assert_match(/products\.updated_at DESC/, sql)
  end

  def test_bm25_search_model_defaults_merged
    sql = DocumentWithDefaults.bm25_search(:content, "database").to_sql
    assert_match(/unaccent/, sql)
    assert_match(/database:\*/, sql)
  end
end

class PgTextsearchMaintenanceTest < Minitest::Test
  def test_maintenance_module_functions_exist
    assert PgTextsearch::Maintenance.respond_to?(:needs_compaction?)
    assert PgTextsearch::Maintenance.respond_to?(:compact)
    assert PgTextsearch::Maintenance.respond_to?(:compact_step)
    assert PgTextsearch::Maintenance.respond_to?(:spill_index)
    assert PgTextsearch::Maintenance.respond_to?(:level_counts)
    assert PgTextsearch::Maintenance.respond_to?(:unaccent_available?)
    assert PgTextsearch::Maintenance.respond_to?(:enable_unaccent!)
    assert PgTextsearch::Maintenance.respond_to?(:pg_trgm_available?)
    assert PgTextsearch::Maintenance.respond_to?(:enable_pg_trgm!)
    assert PgTextsearch::Maintenance.respond_to?(:thesaurus_available?)
    assert PgTextsearch::Maintenance.respond_to?(:enable_thesaurus!)
  end
end

class PgTextsearchSchemaTest < Minitest::Test
  def test_schema_modules_defined
    assert defined?(PgTextsearch::SchemaStatements)
    assert defined?(PgTextsearch::SchemaDumper)
  end
end