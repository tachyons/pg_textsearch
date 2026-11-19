#!/usr/bin/env ruby
# frozen_string_literal: true
# Fuzzy search (pg_trgm) and Synonyms (thesaurus)
# Run: ruby samples/05_fuzzy_synonyms.rb

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

def setup_schema
  conn = ActiveRecord::Base.connection
  conn.execute("CREATE EXTENSION IF NOT EXISTS pg_textsearch")
  conn.execute("DROP TABLE IF EXISTS products CASCADE")
  conn.execute(<<~SQL)
    CREATE TABLE products (
      id BIGSERIAL PRIMARY KEY,
      name TEXT NOT NULL,
      description TEXT,
      search_text TEXT
    )
  SQL
  conn.execute(<<~SQL)
    CREATE INDEX products_search_idx ON products
    USING bm25 (search_text)
    WITH (text_config = 'english', k1 = 1.5, b = 0.75);
  SQL
  puts "✓ Schema created"
end

def seed_data
  Product.delete_all
  products = [
    { name: "Sony WH-1000XM5", description: "Industry-leading noise cancellation with Auto NC Optimizer" },
    { name: "Bose QuietComfort Ultra", description: "World-class noise cancellation. Spatial audio." },
    { name: "Apple AirPods Pro", description: "Active Noise Cancellation. Transparency mode." },
    { name: "Sennheiser Momentum 4", description: "Audiophile sound. 60-hour battery." },
    { name: "Sony WF-1000XM5", description: "Best-in-class noise cancellation in earbud form" },
    { name: "Jabra Elite 10", description: "Dolby Atmos spatial audio. Advanced ANC." },
    { name: "Sony WH-CH720N", description: "Lightweight noise cancellation. 35-hour battery." },
    { name: "Bose QuietComfort 45", description: "Proven noise cancellation. Comfortable fit." },
    { name: "Sennheiser Accentum", description: "Great value ANC. 50-hour battery." },
    { name: "Nothing Ear (2)", description: "Transparent design. ANC. 36-hour battery." }
  ]

  products.each do |p|
    p[:search_text] = [p[:name], p[:description]].compact.join(" ")
    Product.create!(p)
  end
  puts "✓ Seeded #{Product.count} products"
end

class Product < ActiveRecord::Base
  has_bm25 :search_text, index: :products_search_idx
end

def run
  setup_schema
  seed_data

  puts "\n=== Fuzzy Search (pg_trgm) ==="
  if PgTextsearch::Maintenance.pg_trgm_available?
    # Matches "headphon" -> "headphones" (typo tolerance via trigram similarity)
    # Using search_text column which has the products_search_idx
    results = Product.bm25_search(:search_text, "headphon", index: :products_search_idx,
                                  fuzzy: {threshold: 0.3}).limit(5)
    results.each { |p| puts "  #{p.name}" }

    puts "\n  Fuzzy: 'zucini' -> 'zucchini' style matching"
    results = Product.bm25_search(:search_text, "airpod", index: :products_search_idx,
                                  fuzzy: {threshold: 0.3}).limit(5)
    results.each { |p| puts "  #{p.name}" }
  else
    puts "  pg_trgm extension not installed"
    puts "  Run: PgTextsearch::Maintenance.enable_pg_trgm!"
    puts "  Then: CREATE EXTENSION pg_trgm;"
  end

  puts "\n=== Synonyms (Thesaurus Dictionary) ==="
  if PgTextsearch::Maintenance.thesaurus_available?("thesaurus_en")
    puts "  thesaurus_en dictionary available"
    puts "  Search 'pop' -> would match 'soda' products"
    puts "  (Requires index created with thesaurus text_config)"
  else
    puts "  thesaurus dictionary not installed"
    puts "  Run: PgTextsearch::Maintenance.enable_thesaurus!('thesaurus_en', 'thesaurus_en')"
    puts "  Requires thesaurus_en.ths file in \$SHAREDIR/tsearch_data/"
  end

  puts "\n✅ Fuzzy & synonyms examples completed!"
end

run if $PROGRAM_NAME == __FILE__