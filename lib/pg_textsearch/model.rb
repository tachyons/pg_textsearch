# frozen_string_literal: true

module PgTextsearch
  # Extended into ActiveRecord::Base. Wraps the awkward SQL bits (`<@>` and
  # `to_bm25query`) and returns plain relations so the rest of ActiveRecord
  # composes unchanged.
  module Model
    def self.extended(base)
      base.class_attribute :bm25_indexes, instance_accessor: false, default: {}
      base.class_attribute :bm25_expressions, instance_accessor: false, default: {}
      base.class_attribute :bm25_default_options, instance_accessor: false, default: {}
    end

    # has_bm25 :content, index: :docs_idx, unaccent: true, synonyms: true
    # has_bm25 "data->>'description'", index: :events_expr_idx
    # has_bm25 :description_expr, index: :events_expr_idx, expression: "data->>'description'"
    def has_bm25(target, index:, expression: nil, **default_options)
      self.bm25_indexes = bm25_indexes.merge(target.to_s => index.to_s)
      expr = expression == true ? target.to_s : expression
      self.bm25_expressions = bm25_expressions.merge(target.to_s => expr) unless expr.nil? || expr == false
      self.bm25_default_options = bm25_default_options.merge(target.to_s => default_options)
    end

    # Document.bm25_search(:content, "database system", index: :docs_idx,
    #   prefix: true, any_word: true, negation: true, unaccent: true,
    #   fuzzy: {threshold: 0.3}, synonyms: true,
    #   select_score: true, select_score_only: false, highlight: true,
    #   ranked_by: "expr", order_within_rank: "col DESC", where: true, filter: true
    # ).limit(5)
    def bm25_search(target, query, index: nil, **options)
      ensure_pg_textsearch_available!

      defaults = bm25_default_options[target.to_s] || {}
      options = defaults.merge(options)

      index ||= bm25_indexes[target.to_s]
      expression = bm25_expressions[target.to_s]

      target_for_sql = expression || target
      target_sql = bm25_target_sql(target_for_sql, options[:unaccent])
      query_sql = bm25_query_sql(query, index, options)
      score_sql = "#{target_sql} <@> #{query_sql}"

      relation = if options[:select_score_only]
                   all
                 else
                   order(*build_order_clauses(score_sql, options))
                 end

      score_opt = options[:select_score] || options[:select_score_only]
      if score_opt
        alias_name = score_opt == true ? "bm25_score" : score_opt.to_s
        relation = append_select(relation, score_sql, alias_name)
      end

      relation = apply_highlight(relation, target, query, index, options[:highlight]) if options[:highlight]

      if options[:fuzzy] && options[:where] != false
        relation = apply_fuzzy(relation, target, query, options[:fuzzy])
      end

      if options[:filter] != false
        relation = relation.where(bm25_match(target, query, index: index, **options))
      end

      relation
    end

    # Match operator for use in WHERE clauses
    # Usage: scope.where(Event.bm25_match("data->>'description'", "query", index: :idx))
    def bm25_match(target, query, index: nil, **options)
      ensure_pg_textsearch_available!

      defaults = bm25_default_options[target.to_s] || {}
      options = defaults.merge(options)

      index ||= bm25_indexes[target.to_s]
      expression = bm25_expressions[target.to_s]
      target_for_sql = expression || target
      query_sql = bm25_query_sql(query, index, options)
      target_sql = bm25_target_sql(target_for_sql, options[:unaccent])

      predicate = if options[:prefix]
                    bm25_prefix_filter_sql(target_sql, query, options)
                  else
                    "#{target_sql} <@> #{query_sql} < 0"
                  end
      Arel.sql(predicate)
    end

    private

    def append_select(relation, sql, alias_name)
      expr = Arel.sql("#{sql} AS #{connection.quote_column_name(alias_name)}")
      if relation.select_values.empty?
        relation.select(arel_table[Arel.star], expr)
      else
        relation.select(expr)
      end
    end

    def bm25_target_sql(target, unaccent = false)
      base = case target
             when Symbol then connection.quote_column_name(target)
             when Arel::Nodes::Node, Arel::Attributes::Attribute then target.to_sql
             else target.to_s
             end
      unaccent ? "unaccent(#{base})" : base
    end

    def bm25_query_sql(query, index, options)
      q = bm25_processed_query_text(query, options)

      query_arg = if options[:unaccent]
                    "unaccent(#{connection.quote(q)})"
                  else
                    connection.quote(q)
                  end

      if index
        "to_bm25query(#{query_arg}, #{connection.quote(index.to_s)})"
      else
        "to_bm25query(#{query_arg})"
      end
    end

    def bm25_processed_query_text(query, options)
      words = query.to_s.split
      words = words.map { |w| "#{w}:*" } if options[:prefix]

      if options[:any_word]
        words.join(" | ")
      else
        words.join(" ")
      end
    end

    def bm25_prefix_filter_sql(target_sql, query, options)
      lexemes = query.to_s.split.map { |w| "'#{w.gsub("'", "''")}':*" }
      tsquery_text = if options[:any_word]
                       lexemes.join(" | ")
                     else
                       lexemes.join(" & ")
                     end

      config = options[:text_config] || options[:ts_config] || "english"
      query_arg = if options[:unaccent]
                    "unaccent(#{connection.quote(tsquery_text)})"
                  else
                    connection.quote(tsquery_text)
                  end

      "#{target_sql} @@ to_tsquery(#{connection.quote(config)}, #{query_arg})"
    end

    def build_order_clauses(score_sql, options)
      primary = if options[:ranked_by]
                  options[:ranked_by].gsub(":bm25", "(#{score_sql})")
                else
                  score_sql
                end

      clauses = [Arel.sql(primary)]
      clauses << Arel.sql(options[:order_within_rank]) if options[:order_within_rank]
      clauses
    end

    def apply_highlight(relation, target, query, _index, highlight_opts)
      target_sql = bm25_target_sql(target, false)

      hl_opts = highlight_opts.is_a?(Hash) ? highlight_opts : {}
      opts_str = [
        "StartSel=#{hl_opts[:start_sel] || "<b>"}",
        "StopSel=#{hl_opts[:stop_sel] || "</b>"}",
        "MaxWords=#{hl_opts[:max_words] || 35}",
        "MinWords=#{hl_opts[:min_words] || 15}",
        "ShortWord=#{hl_opts[:short_word] || 3}",
        "HighlightAll=#{hl_opts[:highlight_all] ? "true" : "false"}",
        "MaxFragments=#{hl_opts[:max_fragments] || 0}",
        "FragmentDelimiter=#{hl_opts[:fragment_delimiter] || "..."}"
      ].join(", ")

      highlight_sql = sanitize_sql_array([
                                           "ts_headline('english', #{target_sql}, plainto_tsquery('english', ?), ?)",
                                           query.to_s,
                                           opts_str
                                         ])

      append_select(relation, highlight_sql, "pg_search_highlight")
    end

    def apply_fuzzy(relation, target, query, fuzzy_opts)
      return relation unless Maintenance.pg_trgm_available?

      threshold = fuzzy_opts.is_a?(Hash) ? fuzzy_opts.fetch(:threshold, 0.3) : 0.3
      target_sql = bm25_target_sql(target, false)
      relation.where("similarity(#{target_sql}, ?) > ?", query.to_s, threshold.to_f)
    end

    def ensure_pg_textsearch_available!
      return unless connection.adapter_name.downcase.include?("postgres")
      return if connection.extension_enabled?("pg_textsearch")

      raise StandardError, <<~MSG.squish
        pg_textsearch extension is not enabled. To fix this:

        1. Add to postgresql.conf: shared_preload_libraries = 'pg_textsearch'
        2. Restart PostgreSQL
        3. Run: CREATE EXTENSION pg_textsearch;

        See https://github.com/timescale/pg_textsearch for installation instructions.
      MSG
    end
  end
end