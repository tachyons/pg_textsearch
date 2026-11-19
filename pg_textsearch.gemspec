# frozen_string_literal: true

require_relative "lib/pg_textsearch/version"

Gem::Specification.new do |spec|
  spec.name = "pg_textsearch"
  spec.version = PgTextsearch::VERSION
  spec.authors = ["Aboobacker MK"]
  spec.email = ["aboobackervyd@gmail.com"]

  spec.summary = "Minimal ActiveRecord wrapper for pg_textsearch BM25 indexes"
  spec.description = <<~DESC
    Wraps pg_textsearch's <@> operator, to_bm25query(), and index storage parameters
    (WITH (...)) so you can use BM25 search with standard ActiveRecord relations.
  DESC
  spec.homepage = "https://github.com/timescale/pg_textsearch"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/timescale/pg_textsearch"
  spec.metadata["changelog_uri"] = "https://github.com/timescale/pg_textsearch/blob/main/CHANGELOG.md"

  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == File.basename(__FILE__)) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .github/ .rubocop.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 7.0", "< 9.0"
  spec.add_dependency "activesupport", ">= 7.0", "< 9.0"
end