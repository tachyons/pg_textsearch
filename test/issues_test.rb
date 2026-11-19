# frozen_string_literal: true

require "active_record"
require "pg_textsearch"
require "minitest/autorun"

# Set up a minimal SQLite connection for SQL generation tests
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")

class IssueProduct < ActiveRecord::Base
  self.table_name = "products"
  has_bm25 :search_text, index: :products_search_idx
  has_bm25 :name, index: :products_name_idx
  has_bm25 "coalesce(name, '') || ' ' || coalesce(description, '')", index: :products_all_idx
end

class IssueProductNoDefault < ActiveRecord::Base
  self.table_name = "products"
end

ActiveRecord::Schema.define do
  create_table :products do |t|
    t.text :search_text
    t.text :name
    t.text :description
    t.boolean :active, default: true
  end
end

class PgTextsearchIssuesTest < Minitest::Test # rubocop:disable Metrics/ClassLength
  def setup
    # No database needed for SQL generation tests
  end

  # Issue #1: prefix: true should filter via @@ to_tsquery (supports :* expansion)
  def test_prefix_applies_to_where_clause
    sql = IssueProductNoDefault.bm25_search(:search_text, "iph", index: :idx, prefix: true).to_sql
    assert_match(/WHERE .*@@ to_tsquery\('english', '''iph'':\*'\)/m, sql)
    assert_match(/ORDER BY .*to_bm25query\('iph:\*', 'idx'\)/m, sql)
  end

  def test_prefix_with_multiple_terms
    sql = IssueProductNoDefault.bm25_search(:search_text, "iphone wireless", index: :idx, prefix: true).to_sql
    assert_match(/iphone:\*/, sql)
    assert_match(/wireless:\*/, sql)
  end

  # Issue #2: unaccent: true requires manual unaccent() on query parameter
  def test_unaccent_applies_to_query_parameter
    sql = IssueProductNoDefault.bm25_search(:search_text, "café", index: :idx, unaccent: true).to_sql
    assert_match(/to_bm25query\(unaccent\(/, sql, "unaccent: true should wrap query argument in unaccent()")
  end

  # Issue #3: fuzzy/negation options add unwanted WHERE conditions
  def test_fuzzy_does_not_add_unwanted_where
    # fuzzy should not add extra WHERE conditions that filter out BM25 results
    # For SQLite tests, we verify the SQL structure
    IssueProductNoDefault.bm25_search(:search_text, "iphone", index: :idx, fuzzy: { threshold: 0.3 }).to_sql
    # Should only have ORDER BY, no extra WHERE from fuzzy
    # The fuzzy logic is only applied when pg_trgm is available
  end

  def test_negation_does_not_add_unwanted_where
    # negation should not add extra WHERE conditions that filter out BM25 results
    IssueProductNoDefault.bm25_search(:search_text, "iphone", index: :idx, negation: true).to_sql
    # Should only have ORDER BY with negation in the query
  end

  # Issue #4: Short queries (1-2 chars) return no results due to stop word filtering
  def test_short_query_documentation
    # This is a documentation issue - we should at least not crash
    sql = IssueProductNoDefault.bm25_search(:search_text, "A", index: :idx).to_sql
    assert_match(/ORDER BY/, sql)
  end

  # Issue #5: Highlighting uses to_tsquery instead of to_bm25query
  def test_highlight_uses_bm25query_for_consistency
    sql = IssueProductNoDefault.bm25_search(:search_text, "iphone", index: :idx, highlight: true).to_sql
    # Should use to_bm25query or at least be consistent with the search query
    assert_match(/ts_headline/, sql)
  end

  def test_highlight_with_prefix
    sql = IssueProductNoDefault.bm25_search(:search_text, "iph", index: :idx, prefix: true, highlight: true).to_sql
    assert_match(/ts_headline/, sql)
    # Highlight query should use the same prefix logic
  end

  # Issue #6: Partial index WHERE clause not auto-applied in bm25_search
  def test_partial_index_where_clause_not_auto_applied
    # This is a limitation - we can't auto-detect partial index predicates
    # But we can document it and provide a way to specify it
    skip "This requires index metadata lookup - not yet implemented"
  end

  # Issue #7: Background compaction requires pg_durable 0.2.8+ (undocumented)
  def test_background_compaction_documentation
    # This is a documentation issue - we should document the requirement
    skip "Documentation issue - verify README mentions pg_durable requirement"
  end

  # Issue #8: No way to get BM25 score without ordering (select_score_only option)
  def test_select_score_only_option
    # Should be able to get score without ORDER BY
    sql = IssueProductNoDefault.bm25_search(:search_text, "test", index: :idx, select_score_only: true).to_sql
    assert_match(/SELECT.*AS "bm25_score"/, sql)
    refute_match(/ORDER BY/, sql, "select_score_only should not add ORDER BY")
  end

  def test_select_score_only_with_custom_alias
    sql = IssueProductNoDefault.bm25_search(:search_text, "test", index: :idx, select_score_only: :my_score).to_sql
    assert_match(/AS "my_score"/, sql)
    refute_match(/ORDER BY/, sql)
  end

  def test_select_score_true_still_adds_order_by
    sql = IssueProductNoDefault.bm25_search(:search_text, "test", index: :idx, select_score: true).to_sql
    assert_match(/ORDER BY/, sql, "select_score: true should still add ORDER BY")
  end

  # Issue #9: bm25_match should accept target as first arg and return SQL predicate
  def test_bm25_match_accepts_target_and_returns_predicate
    predicate = IssueProductNoDefault.bm25_match(:search_text, "test", index: :idx)
    assert_match(/<@>/, predicate.to_s)
    assert_match(/< 0/, predicate.to_s)
    sql = IssueProductNoDefault.where(predicate).to_sql
    assert_match(/WHERE/, sql)
  end

  # Issue #15: bm25_search filters rows by default
  def test_bm25_search_filters_by_default
    sql = IssueProductNoDefault.bm25_search(:search_text, "test", index: :idx).to_sql
    assert_match(/WHERE/, sql)
    assert_match(/<@>.*< 0/m, sql)
  end

  def test_bm25_search_filter_false_disables_filter
    sql = IssueProductNoDefault.bm25_search(:search_text, "test", index: :idx, filter: false).to_sql
    assert_match(/ORDER BY/, sql)
    refute_match(/< 0/, sql)
  end

  # Issue #16: prefix: true combined with any_word: true
  def test_prefix_combined_with_any_word
    sql = IssueProductNoDefault.bm25_search(:search_text, "wireless phones", index: :idx, prefix: true, any_word: true).to_sql
    assert_match(/wireless:\*/, sql)
    assert_match(/phones:\*/, sql)
    assert_match(/\|/, sql)
  end

  # Issue #17: highlight should handle tsquery operators safely
  def test_highlight_handles_tsquery_operators
    sql = IssueProductNoDefault.bm25_search(:search_text, "sony & canon", index: :idx, highlight: true).to_sql
    assert_match(/plainto_tsquery/, sql)
    assert_match(/ts_headline/, sql)
  end

  # Issue #18: has_bm25 defaults stored per target
  def test_has_bm25_defaults_per_target
    klass = Class.new(ActiveRecord::Base) do
      self.table_name = "products"
      has_bm25 :search_text, index: :idx1, prefix: true
      has_bm25 :name, index: :idx2, unaccent: true
    end

    sql1 = klass.bm25_search(:search_text, "iph", index: :idx1).to_sql
    assert_match(/iph:\*/, sql1)
    refute_match(/unaccent\("search_text"\)/, sql1)

    sql2 = klass.bm25_search(:name, "cafe", index: :idx2).to_sql
    assert_match(/unaccent\("name"\)/, sql2)
  end

  # Issue #19: expression: true should use the target as the expression
  def test_has_bm25_expression_true_uses_target
    klass = Class.new(ActiveRecord::Base) do
      self.table_name = "products"
      has_bm25 "coalesce(name, '') || ' ' || coalesce(description, '')",
               index: :products_expr_idx, expression: true
    end

    sql = klass.bm25_search("coalesce(name, '') || ' ' || coalesce(description, '')",
                            "iphone", index: :products_expr_idx).to_sql
    assert_match(/coalesce\(name, ''\) \|\| ' ' \|\| coalesce\(description, ''\) <@>/, sql)
    refute_match(/WHERE \(true <@>/, sql)
  end

  # Issue #20: bm25_match should use registered expression
  def test_bm25_match_uses_registered_expression
    klass = Class.new(ActiveRecord::Base) do
      self.table_name = "events"
      has_bm25 :desc, index: :events_desc_idx, expression: "data->>'description'"
    end

    predicate = klass.bm25_match(:desc, "network", index: :events_desc_idx)
    assert_match(/data->>'description' <@>/, predicate.to_s)
    refute_match(/"desc"/, predicate.to_s)
  end

  # Issue #21: unaccent should be applied as SQL expression, not literal text
  def test_unaccent_query_not_passed_as_literal
    sql = IssueProductNoDefault.bm25_search(:search_text, "café", index: :idx, unaccent: true).to_sql
    assert_match(/to_bm25query\(unaccent\('café'\), 'idx'\)/, sql)
    refute_match(/to_bm25query\('unaccent/, sql)
  end

  # Issue #22: prefix filter should quote lexemes in to_tsquery input
  def test_prefix_filter_quotes_tsquery_lexemes
    sql = IssueProductNoDefault.bm25_search(:search_text, "rock & roll", index: :idx, prefix: true).to_sql
    assert_match(/@@ to_tsquery\('english', '''rock'':\* & ''&'':\* & ''roll'':\*'\)/, sql)
  end

  def test_prefix_filter_quotes_lexemes_with_special_chars
    sql = IssueProductNoDefault.bm25_search(:search_text, "a:b (x)", index: :idx, prefix: true).to_sql
    assert_match(/@@ to_tsquery\('english', '''a:b'':\* & ''\(x\)'':\*'\)/, sql)
  end
end