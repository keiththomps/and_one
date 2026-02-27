# frozen_string_literal: true

require_relative "lib/and_one/version"

Gem::Specification.new do |spec|
  spec.name = "and_one"
  spec.version = AndOne::VERSION
  spec.authors = ["Keith Thompson"]
  spec.email = ["keiththomps@hey.com"]

  spec.summary = "Detect N+1 queries in Rails applications with actionable fix suggestions"
  spec.description = "AndOne detects N+1 queries in Rails development and test environments. " \
                     "It stays invisible until a problem is found, then provides the exact " \
                     "query, call site, and a suggested .includes() fix. Zero external dependencies."
  spec.homepage = "https://github.com/keiththomps/and_one"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore test/ .github/ .rubocop.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "railties", ">= 7.0"
  spec.add_dependency "activerecord", ">= 7.0"
  spec.add_dependency "activesupport", ">= 7.0"
end
