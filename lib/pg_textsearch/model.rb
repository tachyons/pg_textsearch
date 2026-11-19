# frozen_string_literal: true

module PgTextsearch
  # Extended into ActiveRecord::Base. Wraps the awkward SQL bits (`<@>` and
  # `to_bm25query`) and returns plain relations so the rest of ActiveRecord
  # composes unchanged.
  module Model
    # has_bm25 :content, index: :docs_idx, unaccent: true, synonyms: true
    # has_bm25 "data->>'description'", index: :events_expr_idx
    # has_bm25 :description_expr, index: :events_expr_idx, expression: "data->>'description'"
    def has_bm25(target, index:, expression: nil, **default_options)
      class_attribute :bm25_indexes, instance_accessor: false, default: {} unless respond_to?(:bm25_indexes)
      class_attribute :bm25_expressions, instance_accessor: false, default: {} unless respond_to?(:bm25_expressions)
      class_attribute :bm25_default_options, instance_accessor: false, default: {} unless respond_to?(:bm25_default_options)
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

      # Merge with model-level defaults (per-target)
      defaults = respond_to?(:bm25_default_options) ? bm25_default_options[target.to_s] || {} : {}
      options = defaults.merge(options)

      index ||= bm25_indexes[target.to_s] if respond_to?(:bm25_indexes)
      expression = bm25_expressions[target.to_s] if respond_to?(:bm25_expressions)

      # Use expression if available, otherwise use target column
      target_for_sql = expression || target
      target_sql = bm25_target_sql(target_for_sql, options[:unaccent])
      query_sql = bm25_query_sql(query, index, options)
      score_sql = "#{target_sql} <@> #{query_sql}"

      # Build ORDER BY (unless select_score_only: true)
      if options[:select_score_only]
        relation = all
      else
        order_sql = build_order_sql(score_sql, options)
        relation = order(Arel.sql(order_sql))
      end

      # Score selection
      name = if options[:select_score] == true || options[:select_score_only] == true
               "bm25_score"
             elsif options[:select_score]
               options[:select_score].to_s
             else
               options[:select_score_only].to_s
             end
      if options[:select_score] || options[:select_score_only]
        relation = relation.select(arel_table[Arel.star],
                                   Arel.sql("#{score_sql} AS #{connection.quote_column_name(name)}"))
      end

      # Highlighting
      relation = apply_highlight(relation, target, query, index, options[:highlight]) if options[:highlight]

      # Fuzzy search (pg_trgm) - adds WHERE clause (unless where: false)
      if options[:fuzzy] && options[:where] != false
        relation = apply_fuzzy(relation, target, query, options[:fuzzy])
      end

      # Filtering - add WHERE clause for actual matching (unless filter: false)
      if options[:filter] != false
        filter_sql = if options[:prefix]
                       bm25_prefix_filter_sql(target_sql, query, options)
                     else
                       "#{target_sql} <@> #{query_sql} < 0"
                     end
        relation = relation.where(Arel.sql(filter_sql))
      end

      # Synonyms - uses thesaurus dictionary (already handled via text_config)
      # Just pass through; the index must be created with thesaurus dict

      relation
    end

    # Match operator for use in WHERE clauses
    # Usage: scope.where(Event.bm25_match("data->>'description'", "query", index: :idx))
    def bm25_match(target, query, index: nil, **options)
      ensure_pg_textsearch_available!

      index ||= bm25_indexes[target.to_s] if respond_to?(:bm25_indexes)
      expression = bm25_expressions[target.to_s] if respond_to?(:bm25_expressions)
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

    def build_order_sql(score_sql, options)
      if options[:ranked_by]
        # Custom ranking expression - wrap score_sql in parentheses for operator precedence
        # <@> has lower precedence than +, so we need (score_sql) + ...
        ranked = options[:ranked_by].gsub(":bm25", "(#{score_sql})")
        base = Arel.sql(ranked)
      else
        base = Arel.sql(score_sql)
      end

      if options[:order_within_rank]
        # Tiebreaker
        Arel.sql("#{base}, #{options[:order_within_rank]}")
      else
        base
      end
    end

    def apply_highlight(relation, target, query, _index, highlight_opts)
      # ts_headline(text, query, [options])
      target_sql = bm25_target_sql(target, false)

      # Build ts_headline options
      hl_opts = highlight_opts.is_a?(Hash) ? highlight_opts : {}
      start_sel = hl_opts[:start_sel] || "<b>"
      stop_sel = hl_opts[:stop_sel] || "</b>"
      max_words = hl_opts[:max_words] || 35
      min_words = hl_opts[:min_words] || 15
      short_word = hl_opts[:short_word] || 3
      highlight_all = hl_opts[:highlight_all] ? "true" : "false"
      max_fragments = hl_opts[:max_fragments] || 0
      fragment_delim = hl_opts[:fragment_delimiter] || "..."

      # ts_headline options string - escape single quotes by doubling
      esc = ->(s) { s.to_s.gsub("'", "''") }
      opts_str = "StartSel=#{esc.call(start_sel)}, StopSel=#{esc.call(stop_sel)}, " \
                 "MaxWords=#{max_words}, MinWords=#{min_words}, " \
                 "ShortWord=#{short_word}, HighlightAll=#{highlight_all}, " \
                 "MaxFragments=#{max_fragments}, FragmentDelimiter=#{esc.call(fragment_delim)}"

      # Use plainto_tsquery for highlighting - handles all user input safely
      tsquery = "plainto_tsquery('english', #{sanitize_sql_array(["?", query.to_s])})"
      # The opts_str is a string literal in SQL, so escape internal single quotes
      highlight_sql = "ts_headline('english', #{target_sql}, #{tsquery}, '#{opts_str.gsub("'", "''")}')"

      alias_name = "pg_search_highlight"
      relation.select(arel_table[Arel.star],
                      Arel.sql("#{highlight_sql} AS #{connection.quote_column_name(alias_name)}"))
    end

    def apply_fuzzy(relation, target, query, fuzzy_opts)
      # Uses pg_trgm similarity for fuzzy matching
      # Adds WHERE similarity(target, query) > threshold
      return relation unless Maintenance.pg_trgm_available?

      threshold = fuzzy_opts.is_a?(Hash) ? (fuzzy_opts[:threshold] || 0.3) : 0.3
      target_sql = bm25_target_sql(target, false)
      q = connection.quote(query.to_s)

      where_sql = "similarity(#{target_sql}, #{q}) > #{threshold}"
      relation.where(Arel.sql(where_sql))
    end

    def ensure_pg_textsearch_available!
      return unless connection.adapter_name.downcase.include?("postgres")
      return if connection.extensions.include?("pg_textsearch")

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