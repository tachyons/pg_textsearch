#!/usr/bin/env ruby
# frozen_string_literal: true
# Enable optional PostgreSQL extensions for advanced features
# Run: ruby samples/07_extension_setup.rb

require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "activerecord", ">= 7.0"
  gem "pg", ">= 1.5"
  gem "pg_textsearch", path: File.expand_path("..", __dir__)
end

require "active_record"
require "pg_textsearch"
require "logger"

DB_CONFIG = {
  adapter: "postgresql",
  database: ENV.fetch("PG_DATABASE", "pg_textsearch_test"),
  username: ENV.fetch("PG_USER", "postgres"),
  password: ENV.fetch("PG_PASSWORD", "postgres"),
  host: ENV.fetch("PG_HOST", "localhost"),
  port: ENV.fetch("PG_PORT", 5432)
}.freeze

ActiveRecord::Base.establish_connection(DB_CONFIG)

def run
  puts "=== Extension Setup Helpers ===\n"

  # unaccent: accent-insensitive search
  puts "1. unaccent (accent-insensitive search)"
  puts "   Available: #{PgTextsearch::Maintenance.unaccent_available?}"
  if !PgTextsearch::Maintenance.unaccent_available?
    puts "   To enable: PgTextsearch::Maintenance.enable_unaccent!"
    puts "   This creates the extension and an IMMUTABLE wrapper function"
  end
  puts

  # pg_trgm: fuzzy/prefix matching
  puts "2. pg_trgm (fuzzy/prefix matching)"
  puts "   Available: #{PgTextsearch::Maintenance.pg_trgm_available?}"
  if !PgTextsearch::Maintenance.pg_trgm_available?
    puts "   To enable: PgTextsearch::Maintenance.enable_pg_trgm!"
    puts "   Then use: fuzzy: {threshold: 0.3} in bm25_search"
  end
  puts

  # thesaurus: synonyms
  puts "3. thesaurus (synonym dictionary)"
  puts "   Available: #{PgTextsearch::Maintenance.thesaurus_available?('thesaurus_en')}"
  if !PgTextsearch::Maintenance.thesaurus_available?('thesaurus_en')
    puts "   To enable: PgTextsearch::Maintenance.enable_thesaurus!('thesaurus_en', 'thesaurus_en')"
    puts "   Requires thesaurus_en.ths file in \$SHAREDIR/tsearch_data/"
    puts "   Example thesaurus file content:"
    puts "     pop, soda, cola"
    puts "     headphones, earphones, cans"
    puts "     laptop, notebook"
  end
  puts

  puts "=== Usage in bm25_search ==="
  puts <<~RUBY
    # Unaccent
    Product.bm25_search(:name, "cafe", index: :idx, unaccent: true)

    # Fuzzy (requires pg_trgm)
    Product.bm25_search(:name, "headphon", index: :idx, fuzzy: {threshold: 0.3})

    # Synonyms (requires thesaurus dict in index text_config)
    Product.bm25_search(:name, "pop", index: :idx, synonyms: true)

    # Combined
    Product.bm25_search(:search_text, "headphones", index: :idx,
      unaccent: true,
      prefix: true,
      any_word: true,
      negation: true,
      fuzzy: {threshold: 0.3},
      highlight: true,
      ranked_by: ":bm25 + 0.1 * products.popularity",
      order_within_rank: "products.updated_at DESC"
    )
  RUBY
end

run if $PROGRAM_NAME == __FILE__