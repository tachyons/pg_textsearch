# frozen_string_literal: true

require "active_record"
require "pg_textsearch"
require "minitest/autorun"

ActiveRecord::Base.establish_connection(
  adapter: "postgresql",
  database: "pg_textsearch_test"
)

class Document < ActiveRecord::Base
  self.table_name = "documents"
  has_bm25 :content, index: :docs_idx
end

ActiveRecord::Schema.define do
  create_table :documents, force: true do |t|
    t.text :content
    t.integer :category_id
  end

  enable_extension "pg_textsearch"

  execute "CREATE INDEX docs_idx ON documents USING bm25(content) WITH (text_config='english')"
end

class PgTextsearchIntegrationTest < Minitest::Test
  def setup
    Document.delete_all
    Document.create!([
                       { content: "PostgreSQL is a powerful database system", category_id: 1 },
                       { content: "BM25 is an effective ranking function", category_id: 1 },
                       { content: "Full text search with custom scoring", category_id: 2 },
                       { content: "Database indexes improve query performance", category_id: 2 },
                       { content: "PostgreSQL full text search tutorial", category_id: 1 }
                     ])
  end

  def test_bm25_search_returns_results
    results = Document.bm25_search(:content, "database system", index: :docs_idx).limit(3).to_a
    assert results.size >= 1
    assert results.first.content.include?("database") || results.first.content.include?("PostgreSQL")
  end

  def test_bm25_search_with_has_bm25_declaration
    results = Document.bm25_search(:content, "database system").limit(3).to_a
    assert results.size >= 1
  end

  def test_bm25_search_composes_with_where
    results = Document.where(category_id: 1).bm25_search(:content, "database", index: :docs_idx).to_a
    assert(results.all? { |d| d.category_id == 1 })
    assert(results.any? { |d| d.content.include?("database") || d.content.include?("PostgreSQL") })
  end

  def test_bm25_search_with_select_score
    results = Document.bm25_search(:content, "database system", index: :docs_idx, select_score: true).limit(3).to_a
    assert results.first.respond_to?(:bm25_score)
    assert results.first.bm25_score.is_a?(Numeric)
    assert results.first.bm25_score <= 0 # BM25 scores are negative
  end

  def test_bm25_search_with_custom_score_alias
    results = Document.bm25_search(:content, "database system", index: :docs_idx, select_score: :my_score).limit(3).to_a
    assert results.first.respond_to?(:my_score)
    assert results.first.my_score.is_a?(Numeric)
  end

  def test_bm25_search_with_arel_expression
    arel = Arel.sql("(data->>'description')")
    # This test just verifies SQL generation works; we don't have a JSON column here
    sql = Document.bm25_search(arel, "network error", index: :events_expr_idx).to_sql
    assert_match(/ORDER BY \(data->>'description'\) <@> to_bm25query/, sql)
  end

  def test_bm25_search_with_raw_sql_string
    sql = Document.bm25_search("data->>'description'", "network error", index: :events_expr_idx).to_sql
    assert_match(/ORDER BY data->>'description' <@> to_bm25query/, sql)
  end

  def test_bm25_search_scores_are_ordered
    results = Document.bm25_search(:content, "database", index: :docs_idx, select_score: true).to_a
    scores = results.map(&:bm25_score)
    assert_equal scores.sort, scores # Should be in ascending order (more negative = better)
  end
end

class PgTextsearchMaintenanceIntegrationTest < Minitest::Test
  def setup
    Document.delete_all
    Document.create!([
                       { content: "PostgreSQL is a powerful database system" },
                       { content: "BM25 is an effective ranking function" }
                     ])
  end

  def test_needs_compaction_returns_boolean
    result = PgTextsearch::Maintenance.needs_compaction?(:docs_idx)
    assert [true, false].include?(result)
  end

  def test_compact_returns_void
    result = PgTextsearch::Maintenance.compact(:docs_idx)
    # bm25_compact returns void, which comes back as empty string
    assert [true, false, ""].include?(result)
  end

  def test_compact_step_returns_boolean
    result = PgTextsearch::Maintenance.compact_step(:docs_idx)
    assert [true, false].include?(result)
    # false means no compaction pass was run (nothing to do), which is expected
  end

  def test_spill_index_returns_integer
    result = PgTextsearch::Maintenance.spill_index(:docs_idx)
    assert result.is_a?(Integer)
  end

  def test_level_counts_returns_array
    result = PgTextsearch::Maintenance.level_counts(:docs_idx)
    assert result.is_a?(Array)
    assert(result.all? { |v| v.is_a?(Integer) })
  end
end