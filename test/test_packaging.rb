# frozen_string_literal: true

require "test_helper"
require "rubygems/package"
require "open3"
require "rbconfig"

class TestPackaging < Minitest::Test
  def test_built_gem_contains_only_runtime_and_documentation_and_loads
    root = File.expand_path("..", __dir__)
    spec = Gem::Specification.load(File.join(root, "and_one.gemspec"))
    Dir.mktmpdir("and_one_package") do |directory|
      spec.files.each do |file|
        destination = File.join(directory, file)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(File.join(root, file), destination)
      end
      capture_io { Dir.chdir(directory) { Gem::Package.build(spec) } }
      package = Gem::Package.new(File.join(directory, spec.file_name))
      assert_includes package.contents, "lib/and_one.rb"
      assert_includes package.contents, "lib/and_one/test_capture.rb"
      assert_includes package.contents, "README.md"
      assert_includes package.contents, "LICENSE.txt"
      assert_includes package.contents, "docs/sql-fingerprints.md"
      assert_includes package.contents, "exe/and-one"
      assert_includes package.contents, "skills/and-one/SKILL.md"
      assert_equal ["and-one"], spec.executables
      assert(package.contents.all? { |file| file.match?(%r{\A(?:lib/.*\.rb|exe/and-one|skills/.*\.md|docs/.*\.md|README\.md|CHANGELOG\.md|LICENSE\.txt)\z}) })
      installed = File.join(directory, "installed")
      package.extract_files(installed)
      output, status = Open3.capture2e(RbConfig.ruby, "-I", File.join(installed, "lib"), "-e", 'require "and_one"', chdir: directory)
      assert status.success?, output
      output, status = Open3.capture2e(RbConfig.ruby, "-I", File.join(installed, "lib"),
                                       File.join(installed, "exe/and-one"), "skill", "install", "--json", chdir: directory)
      assert status.success?, output
      assert File.file?(File.join(directory, ".agents/skills/and-one/SKILL.md"))
    end
  end
end
