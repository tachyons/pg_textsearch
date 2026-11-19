#!/usr/bin/env ruby
# frozen_string_literal: true
# Basic search with pg_textsearch
# Run: ruby samples/01_basic_search.rb

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
ActiveRecord::Base.logger = Logger.new($stdout) if ENV["DEBUG"]

# --- Schema ---
def setup_schema
  conn = ActiveRecord::Base.connection
  conn.execute("CREATE EXTENSION IF NOT EXISTS pg_textsearch")
  conn.execute("DROP TABLE IF EXISTS products CASCADE")
  conn.execute(<<~SQL)
    CREATE TABLE products (
      id BIGSERIAL PRIMARY KEY,
      name TEXT NOT NULL,
      description TEXT,
      category VARCHAR(50),
      brand VARCHAR(50),
      price NUMERIC(10,2),
      active BOOLEAN DEFAULT true,
      search_text TEXT
    )
  SQL
  conn.execute(<<~SQL)
    CREATE INDEX products_search_idx ON products
    USING bm25 (search_text)
    WITH (text_config = 'english', k1 = 1.5, b = 0.75);
  SQL
  conn.execute(<<~SQL)
    CREATE INDEX products_name_idx ON products USING bm25 (name)
    WITH (text_config = 'english');
  SQL
  puts "✓ Schema created"
end

def seed_data
  Product.delete_all
  products = [
    { name: "Sony WH-1000XM5 Wireless Headphones", description: "Industry-leading noise cancellation", category: "electronics", brand: "Sony", price: 399.99, active: true },
    { name: "Bose QuietComfort Ultra Headphones", description: "World-class noise cancellation", category: "electronics", brand: "Bose", price: 429.00, active: true },
    { name: "Apple AirPods Pro (2nd Gen)", description: "Active Noise Cancellation", category: "electronics", brand: "Apple", price: 249.00, active: true },
    { name: "Sennheiser Momentum 4 Wireless", description: "Audiophile sound", category: "electronics", brand: "Sennheiser", price: 379.95, active: true },
    { name: "Sony WF-1000XM5 Earbuds", description: "Best-in-class noise cancellation in earbud form", category: "electronics", brand: "Sony", price: 299.99, active: true },
    { name: "Jabra Elite 10", description: "Dolby Atmos spatial audio", category: "electronics", brand: "Jabra", price: 249.99, active: true },
    { name: "Sony WH-CH720N Budget Headphones", description: "Lightweight noise cancellation", category: "electronics", brand: "Sony", price: 149.99, active: true },
    { name: "Bose QuietComfort 45", description: "Proven noise cancellation", category: "electronics", brand: "Bose", price: 329.00, active: true },
    { name: "Sennheiser Accentum Wireless", description: "Great value ANC", category: "electronics", brand: "Sennheiser", price: 179.95, active: true },
    { name: "Nothing Ear (2)", description: "Transparent design ANC", category: "electronics", brand: "Nothing", price: 149.00, active: true }
  ]

  products.each do |p|
    p[:search_text] = [p[:name], p[:description]].compact.join(" ")
    Product.create!(p)
  end
  puts "✓ Seeded #{Product.count} products"
end

class Product < ActiveRecord::Base
  has_bm25 :search_text, index: :products_search_idx
  has_bm25 :name, index: :products_name_idx
end

def run
  setup_schema
  seed_data

  puts "\n=== Basic Search ==="
  results = Product.where(active: true)
                   .bm25_search(:search_text, "wireless headphones", index: :products_search_idx)
                   .limit(5)
  results.each { |p| puts "  #{p.name} (#{p.brand})" }

  puts "\n=== Search with Score ==="
  results = Product.where(active: true)
                   .bm25_search(:search_text, "headphones", index: :products_search_idx, select_score: true)
                   .limit(5)
  results.each { |p| puts "  #{p.name}: score = #{p.bm25_score&.round(3)}" }

  puts "\n=== Search Composed with WHERE ==="
  results = Product.where(active: true, category: "electronics")
                   .where("price BETWEEN ? AND ?", 200, 400)
                   .bm25_search(:search_text, "noise cancelling", index: :products_search_idx)
                   .limit(5)
  results.each { |p| puts "  #{p.name} - $#{p.price}" }

  puts "\n✅ Basic search examples completed!"
end

run if $PROGRAM_NAME == __FILE__