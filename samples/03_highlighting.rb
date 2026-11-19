#!/usr/bin/env ruby
# frozen_string_literal: true
# Highlighting with ts_headline
# Run: ruby samples/03_highlighting.rb

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
    { name: "Sony WH-1000XM5", description: "Industry-leading noise cancellation with Auto NC Optimizer. 30-hour battery life. Multipoint connection." },
    { name: "Bose QuietComfort Ultra", description: "World-class noise cancellation. Spatial audio. 24-hour battery. Premium comfort." },
    { name: "Apple AirPods Pro", description: "Active Noise Cancellation. Transparency mode. Adaptive Audio. USB-C charging." },
    { name: "Sennheiser Momentum 4", description: "Audiophile sound. 60-hour battery. Adaptive noise cancellation. Premium build." },
    { name: "Sony WF-1000XM5", description: "Best-in-class noise cancellation in earbud form. 8-hour battery. LDAC support." }
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

  puts "\n=== Basic Highlighting ==="
  results = Product.bm25_search(:search_text, "wireless", index: :products_search_idx,
                                highlight: true).limit(3)
  results.each do |p|
    puts "  #{p.name}"
    puts "    #{p.pg_search_highlight&.truncate(120)}"
  end

  puts "\n=== Custom Highlight Options ==="
  results = Product.bm25_search(:search_text, "noise cancellation", index: :products_search_idx,
                                highlight: {
                                  start_sel: "<mark>",
                                  stop_sel: "</mark>",
                                  max_words: 30,
                                  min_words: 10,
                                  fragment_delimiter: " ... "
                                }).limit(3)
  results.each do |p|
    puts "  #{p.name}"
    puts "    #{p.pg_search_highlight&.truncate(120)}"
  end

  puts "\n✅ Highlighting examples completed!"
end

run if $PROGRAM_NAME == __FILE__