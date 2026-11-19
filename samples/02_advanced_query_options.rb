#!/usr/bin/env ruby
# frozen_string_literal: true
# Advanced query options: prefix, any_word, negation, unaccent
# Run: ruby samples/02_advanced_query_options.rb

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

  puts "\n=== Prefix Matching (autocomplete) ==="
  # "iph" matches "iphone", "Wire" etc.
  results = Product.bm25_search(:search_text, "wire", index: :products_search_idx, prefix: true).limit(5)
  results.each { |p| puts "  #{p.name}" }

  puts "\n=== Any Word (OR) ==="
  # Matches "sony" OR "bose" OR "wireless"
  results = Product.bm25_search(:search_text, "sony bose wireless", index: :products_search_idx, any_word: true).limit(5)
  results.each { |p| puts "  #{p.name}" }

  puts "\n=== Negation (Exclude Terms) ==="
  # Matches "wireless" but NOT "sony"
  results = Product.bm25_search(:search_text, "wireless !sony", index: :products_search_idx, negation: true).limit(5)
  results.each { |p| puts "  #{p.name}" }

  puts "\n=== Unaccent (Accent Insensitivity) ==="
  if PgTextsearch::Maintenance.unaccent_available?
    puts "  unaccent available - would match 'café' when searching 'cafe'"
  else
    puts "  unaccent not installed"
    puts "  Run: PgTextsearch::Maintenance.enable_unaccent!"
  end

  puts "\n✅ Advanced query options completed!"
end

run if $PROGRAM_NAME == __FILE__