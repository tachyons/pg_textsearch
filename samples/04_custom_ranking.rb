#!/usr/bin/env ruby
# frozen_string_literal: true
# Custom ranking with ranked_by and order_within_rank
# Run: ruby samples/04_custom_ranking.rb

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
      search_text TEXT,
      popularity INT DEFAULT 0,    -- e.g., view count
      rating NUMERIC(2,1) DEFAULT 0,
      updated_at TIMESTAMPTZ DEFAULT now()
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
    { name: "Sony WH-1000XM5", description: "Industry-leading noise cancellation", popularity: 10000, rating: 4.8 },
    { name: "Bose QuietComfort Ultra", description: "World-class noise cancellation", popularity: 8000, rating: 4.7 },
    { name: "Apple AirPods Pro", description: "Active Noise Cancellation", popularity: 15000, rating: 4.9 },
    { name: "Sennheiser Momentum 4", description: "Audiophile sound", popularity: 3000, rating: 4.6 },
    { name: "Sony WF-1000XM5", description: "Best-in-class noise cancellation earbuds", popularity: 7000, rating: 4.7 },
    { name: "Jabra Elite 10", description: "Dolby Atmos spatial audio", popularity: 2000, rating: 4.5 },
    { name: "Sony WH-CH720N", description: "Lightweight noise cancellation", popularity: 5000, rating: 4.3 },
    { name: "Bose QuietComfort 45", description: "Proven noise cancellation", popularity: 6000, rating: 4.6 },
    { name: "Sennheiser Accentum", description: "Great value ANC", popularity: 1500, rating: 4.4 },
    { name: "Nothing Ear (2)", description: "Transparent design ANC", popularity: 4000, rating: 4.2 }
  ]

  products.each_with_index do |p, i|
    p[:search_text] = [p[:name], p[:description]].compact.join(" ")
    p[:updated_at] = Time.now - (i * 86400)  # different update times
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

  puts "\n=== Default BM25 Ranking ==="
  results = Product.bm25_search(:search_text, "headphones", index: :products_search_idx, select_score: true).limit(5)
  results.each { |p| puts "  #{p.name}: score=#{p.bm25_score&.round(3)}, pop=#{p.popularity}" }

  puts "\n=== Custom Ranking: BM25 + Popularity Boost ==="
  # :bm25 is replaced with the actual BM25 score expression
  results = Product.bm25_search(:search_text, "headphones", index: :products_search_idx,
                                ranked_by: ":bm25 + 0.0001 * products.popularity",
                                select_score: true).limit(5)
  results.each { |p| puts "  #{p.name}: score=#{p.bm25_score&.round(3)}, pop=#{p.popularity}" }

  puts "\n=== Custom Ranking: BM25 + Rating Boost ==="
  results = Product.bm25_search(:search_text, "headphones", index: :products_search_idx,
                                ranked_by: ":bm25 + 0.5 * products.rating",
                                select_score: true).limit(5)
  results.each { |p| puts "  #{p.name}: score=#{p.bm25_score&.round(3)}, rating=#{p.rating}" }

  puts "\n=== Tiebreaker: Most Recently Updated First ==="
  results = Product.bm25_search(:search_text, "noise cancellation", index: :products_search_idx,
                                order_within_rank: "products.updated_at DESC",
                                select_score: true).limit(5)
  results.each { |p| puts "  #{p.name}: updated=#{p.updated_at}" }

  puts "\n✅ Custom ranking examples completed!"
end

run if $PROGRAM_NAME == __FILE__