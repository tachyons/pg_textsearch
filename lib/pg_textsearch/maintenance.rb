# frozen_string_literal: true

require "active_record"

module PgTextsearch
  # Thin module-level wrappers for index maintenance. Use in Rake tasks or
  # background jobs. All take an index name (symbol or string).
  module Maintenance
    module_function

    def needs_compaction?(index)
      result = connection.select_value(<<~SQL.squish)
        SELECT bm25_needs_compaction(#{quote(index)})
      SQL
      ActiveModel::Type::Boolean.new.cast(result)
    end

    def compact(index)
      connection.select_value(<<~SQL.squish)
        SELECT bm25_compact(#{quote(index)}::regclass)
      SQL
    end

    def compact_step(index)
      connection.select_value(<<~SQL.squish)
        SELECT bm25_compact_step(#{quote(index)}::regclass)
      SQL
    end

    def spill_index(index)
      connection.select_value(<<~SQL.squish)
        SELECT bm25_spill_index(#{quote(index)})
      SQL
    end

    def level_counts(index)
      result = connection.select_value(<<~SQL.squish)
        SELECT bm25_level_counts(#{quote(index)}::regclass)
      SQL
      result&.tr("{}", "").split(",").map(&:to_i) || []
    end

    # --- Optional Extension Helpers ---

    # unaccent: makes searches accent-insensitive
    # Usage: enable_unaccent! then use unaccent: true in bm25_search
    def unaccent_available?
      extension_installed?("unaccent")
    end

    def enable_unaccent!
      return if unaccent_available?

      connection.execute("CREATE EXTENSION IF NOT EXISTS unaccent")
      # Create wrapper function for indexing (unaccent is not IMMUTABLE by default)
      connection.execute(<<~SQL)
        CREATE OR REPLACE FUNCTION public.unaccent_immutable(text) RETURNS text
        LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
          SELECT public.unaccent('public.unaccent', $1);
        $$;
      SQL
      puts "✓ unaccent enabled. Use unaccent: true in bm25_search"
    end

    # pg_trgm: enables fuzzy/prefix matching
    # Usage: enable_pg_trgm! then use fuzzy: true in bm25_search
    def pg_trgm_available?
      extension_installed?("pg_trgm")
    end

    def enable_pg_trgm!
      return if pg_trgm_available?

      connection.execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")
      puts "✓ pg_trgm enabled. Use fuzzy: {threshold: 0.3} in bm25_search"
    end

    # thesaurus: synonym dictionary
    # Usage: enable_thesaurus!('english', '/path/to/thesaurus_en') then use synonyms: true
    def thesaurus_available?(dict_name = "thesaurus_en")
      result = connection.select_value(<<~SQL)
        SELECT 1 FROM pg_ts_dict WHERE dictname = '#{dict_name}'
      SQL
      !result.nil?
    end

    def enable_thesaurus!(dict_name = "thesaurus_en", dict_file = nil)
      # dict_file should be basename without extension (e.g., 'thesaurus_en')
      # File must be in $SHAREDIR/tsearch_data/
      return if thesaurus_available?(dict_name)

      unless dict_file
        puts "⚠ thesaurus file required. Place #{dict_file}.ths in $SHAREDIR/tsearch_data/"
        return
      end

      connection.execute("CREATE EXTENSION IF NOT EXISTS dict_thesaurus")
      connection.execute(<<~SQL)
        CREATE TEXT SEARCH DICTIONARY #{dict_name} (
          TEMPLATE = thesaurus,
          DictFile = #{quote(dict_file)},
          Dictionary = pg_catalog.english_stem
        );
      SQL
      connection.execute("ALTER TEXT SEARCH CONFIGURATION english ALTER MAPPING FOR asciiword, asciihword, hword_asciipart WITH #{dict_name}, pg_catalog.english_stem;")
      puts "✓ Thesaurus '#{dict_name}' enabled. Use synonyms: true in bm25_search"
    end

    def fuzzy_search_sql(target, query, _index, threshold: 0.3)
      # Uses pg_trgm similarity for fuzzy matching
      # Returns SQL for: similarity(target, query) > threshold
      target_sql = case target
                   when Symbol then connection.quote_column_name(target)
                   when Arel::Nodes::Node, Arel::Attributes::Attribute then target.to_sql
                   else target.to_s
                   end
      q = quote(query.to_s)
      "similarity(#{target_sql}, #{q}) > #{threshold}"
    end

    def connection
      ActiveRecord::Base.connection
    end

    def quote(name)
      ActiveRecord::Base.connection.quote(name.to_s)
    end

    def extension_installed?(name)
      return false unless postgresql?

      !connection.select_value(<<~SQL).nil?
        SELECT 1 FROM pg_extension WHERE extname = '#{name}'
      SQL
    end

    def postgresql?
      connection.adapter_name.downcase.include?("postgres")
    end
  end
end