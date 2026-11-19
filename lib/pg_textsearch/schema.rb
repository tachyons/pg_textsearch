# frozen_string_literal: true

module PgTextsearch
  # Adds index storage parameters to add_index, e.g.
  #
  #   add_index :documents, :content, using: :bm25,
  #     with: { text_config: "english", k1: 1.5 }
  #
  # and surfaces them on IndexDefinition so the schema dumper can emit them.
  module SchemaStatements
    def add_index(table_name, column_name, **options)
      with = options.delete(:with)
      return super if with.blank?

      index, algorithm, if_not_exists = add_index_options(table_name, column_name, **options)
      definition = ActiveRecord::ConnectionAdapters::CreateIndexDefinition.new(index, algorithm, if_not_exists)
      sql = schema_creation.accept(definition)
      with_sql = "WITH (#{with.map { |k, v| "#{k}=#{quote(v)}" }.join(", ")})"
      where_sql = index.where ? " WHERE #{index.where}" : ""
      execute "#{sql.delete_suffix(where_sql)} #{with_sql}#{where_sql}"
      execute "COMMENT ON INDEX #{quote_column_name(index.name)} IS #{quote(index.comment)}" if index.comment
    end

    def indexes(table_name)
      indexes = super
      reloptions = select_rows(<<~SQL.squish, "SCHEMA").to_h
        SELECT c.relname, array_to_string(c.reloptions, ',')
        FROM pg_class c JOIN pg_index i ON i.indexrelid = c.oid
        WHERE i.indrelid = #{quote(quote_table_name(table_name))}::regclass
          AND c.reloptions IS NOT NULL
      SQL
      indexes.each do |index|
        next unless (options = reloptions[index.name])

        index.instance_variable_set(:@with, options.split(",").to_h { |opt| opt.split("=", 2) })
      end
    end
  end

  # Dumps storage parameters back out as `with: { ... }`.
  module SchemaDumper
    private

    def index_parts(index)
      parts = super
      if (with = index.instance_variable_get(:@with))
        formatted = with.map { |k, v| "#{k}: #{(Integer(v, exception: false) || Float(v, exception: false) || v).inspect}" }
        parts << "with: { #{formatted.join(", ")} }"
      end
      parts
    end
  end
end
