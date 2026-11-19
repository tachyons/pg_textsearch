#!/usr/bin/env ruby
# frozen_string_literal: true
# Expression index support and bm25_match fix
# Run: ruby samples/03_expression_indexes.rb

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
  conn.execute("DROP TABLE IF EXISTS events CASCADE")
  conn.execute(<<~SQL)
    CREATE TABLE events (
      id BIGSERIAL PRIMARY KEY,
      data JSONB NOT NULL
    )
  SQL
  
  # Expression index on JSONB field
  conn.execute(<<~SQL)
    CREATE INDEX events_desc_idx ON events
    USING bm25 ((data->>'description'))
    WITH (text_config = 'english');
  SQL
  
  # Expression index on computed text
  conn.execute(<<~SQL)
    CREATE INDEX events_full_idx ON events
    USING bm25 (
      (coalesce(data->>'title', '') || ' ' || coalesce(data->>'description', ''))
    )
    WITH (text_config = 'english');
  SQL
  
  puts "✓ Schema created with expression indexes"
end

def seed_data
  Event.delete_all
  events = [
    { data: { title: "Network Error", description: "Connection timeout on port 8080" } },
    { data: { title: "Database Error", description: "Connection pool exhausted" } },
    { data: { title: "Authentication Error", description: "Invalid credentials for user admin" } },
    { data: { title: "Network Error", description: "DNS resolution failed for api.example.com" } },
    { data: { title: "Cache Error", description: "Redis connection refused" } },
    { data: { title: "Database Error", description: "Deadlock detected on table users" } }
  ]
  
  Event.create!(events)
  puts "✓ Seeded #{Event.count} events"
end

class Event < ActiveRecord::Base
  # Expression index on JSONB description field
  has_bm25 "data->>'description'", index: :events_desc_idx
  
  # Expression index on combined title + description
  has_bm25 "coalesce(data->>'title', '') || ' ' || coalesce(data->>'description', '')", 
           index: :events_full_idx
end

def run
  setup_schema
  seed_data

  puts "\n=== Expression Index: JSONB Description ==="
  results = Event.bm25_search("data->>'description'", "network error", index: :events_desc_idx).limit(3)
  results.each { |e| puts "  #{e.data['title']}: #{e.data['description']}" }

  puts "\n=== Expression Index: Combined Title + Description ==="
  results = Event.bm25_search("coalesce(data->>'title', '') || ' ' || coalesce(data->>'description', '')", 
                              "network", index: :events_full_idx).limit(3)
  results.each { |e| puts "  #{e.data['title']}: #{e.data['description']}" }

  puts "\n=== bm25_match (fixed: target parameter first) ==="
  # Fixed: target parameter is now first argument
  results = Event.where(Event.bm25_match("data->>'description'", "connection timeout", index: :events_desc_idx)).limit(3)
  results.each { |e| puts "  #{e.data['title']}: #{e.data['description']}" }

  puts "\n=== Expression Index with Score ==="
  results = Event.bm25_search("coalesce(data->>'title', '') || ' ' || coalesce(data->>'description', '')",
                              "error", index: :events_full_idx, select_score: true).limit(3)
  results.each { |e| puts "  #{e.data['title']}: score = #{e.bm25_score&.round(3)}" }

  puts "\n✅ Expression index examples completed!"
end

run if $PROGRAM_NAME == __FILE__