# frozen_string_literal: true

require "active_support"
require "active_record"

require_relative "pg_textsearch/version"

module PgTextsearch
  class Error < StandardError; end

  autoload :Model, "pg_textsearch/model"
  autoload :SchemaStatements, "pg_textsearch/schema"
  autoload :SchemaDumper, "pg_textsearch/schema"
  autoload :Maintenance, "pg_textsearch/maintenance"
end

# Extend ActiveRecord::Base with bm25_search / has_bm25
ActiveSupport.on_load(:active_record) do
  extend PgTextsearch::Model
end

# Extend the PostgreSQL adapter with `with:` storage parameters (only if pg adapter is loaded)
ActiveSupport.on_load(:active_record_postgresqladapter) do
  prepend PgTextsearch::SchemaStatements
end

# Extend the schema dumper
ActiveSupport.on_load(:active_record) do
  ActiveRecord::SchemaDumper.prepend(PgTextsearch::SchemaDumper)
end