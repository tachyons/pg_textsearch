#!/usr/bin/env ruby
# frozen_string_literal: true
# Index maintenance operations
# Run: ruby samples/06_maintenance.rb

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
  conn.execute(<<~SQL)
    CREATE INDEX products_name_idx ON products USING bm25 (name)
    WITH (text_config = 'english');
  SQL
  conn.execute(<<~SQL)
    CREATE INDEX products_desc_idx ON products USING bm25 (description)
    WITH (text_config = 'english');
  SQL
  puts "✓ Schema created"
end

def seed_data
  Product.delete_all
  100.times do |i|
    Product.create!(
      name: "Product #{i}",
      description: "Description for product #{i} with some searchable content",
      search_text: "Product #{i} Description for product #{i} with some searchable content"
    )
  end
  puts "✓ Seeded #{Product.count} products"
end

class Product < ActiveRecord::Base
  has_bm25 :search_text, index: :products_search_idx
  has_bm25 :name, index: :products_name_idx
  has_bm25 :description, index: :products_desc_idx
end

def run
  setup_schema
  seed_data

  indexes = %w[products_search_idx products_name_idx products_desc_idx]

  puts "\n=== Check Compaction Status ==="
  indexes.each do |idx|
    needs = PgTextsearch::Maintenance.needs_compaction?(idx)
    levels = PgTextsearch::Maintenance.level_counts(idx)
    puts "  #{idx}: needs_compaction=#{needs}, levels=#{levels}"
  end

  puts "\n=== Compact Step (Cron-Safe) ==="
  indexes.each do |idx|
    ran = PgTextsearch::Maintenance.compact_step(idx)
    puts "  #{idx}: #{ran ? 'ran step' : 'nothing to do'}"
  end

  puts "\n=== Full Compaction ==="
  indexes.each do |idx|
    puts "  Compacting #{idx}..."
    PgTextsearch::Maintenance.compact(idx)
    puts "    Done"
  end

  puts "\n=== Spill Memtables (Post-Bulk-Load) ==="
  indexes.each do |idx|
    pages = PgTextsearch::Maintenance.spill_index(idx)
    puts "  #{idx}: spilled #{pages} pages"
  end

  puts "\n✅ Maintenance examples completed!"
end

run if $PROGRAM_NAME == __FILE__