# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require_relative "version"

module AndOne
  # Explicit, project-local installation; never invoked by gem installation.
  class SkillInstaller
    SOURCE = File.expand_path("../../skills/and-one", __dir__)
    TARGETS = { "agents" => ".agents/skills", "pi" => ".pi/skills", "claude" => ".claude/skills" }.freeze
    MANIFEST = ".and-one-skill.json"

    def initialize(root:, target:)
      @root = File.expand_path(root)
      @destination = File.join(@root, TARGETS.fetch(target), "and-one")
    end

    def install(force: false)
      ensure_safe_destination!
      if File.exist?(@destination) && !force && !unmodified?
        raise CLI::Error.new("modified_skill", "Installed skill has local changes or no valid manifest; review before using --force", 5)
      end

      files = digests(SOURCE)
      FileUtils.rm_rf(@destination)
      FileUtils.mkdir_p(@destination)
      files.each_key do |relative|
        destination = File.join(@destination, relative)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(File.join(SOURCE, relative), destination)
      end
      File.write(File.join(@destination, MANIFEST), "#{JSON.pretty_generate({ version: VERSION, files: files })}\n")
      { skill: { status: "installed", path: @destination, version: VERSION } }
    end

    def check
      ensure_safe_destination!
      unless unmodified? && digests(@destination) == digests(SOURCE) && installed_version == VERSION
        raise CLI::Error.new("skill_out_of_date", "Skill is missing, modified, or differs from the bundled skill", 5)
      end

      { skill: { status: "current", path: @destination, version: VERSION } }
    end

    private

    def ensure_safe_destination!
      path = @destination
      loop do
        raise CLI::Error.new("unsafe_destination", "Skill destination must not contain symlinks") if File.symlink?(path)
        break if path == File.dirname(path)

        path = File.dirname(path)
      end
    end

    def digests(directory)
      Dir.glob("**/*", File::FNM_DOTMATCH, base: directory).sort.each_with_object({}) do |relative, result|
        next if [MANIFEST, ".", ".."].include?(relative)

        file = File.join(directory, relative)
        raise CLI::Error.new("unsafe_destination", "Skill files must not contain symlinks") if File.symlink?(file)
        next if File.directory?(file)

        result[relative] = Digest::SHA256.file(file).hexdigest
      end
    end

    def installed_version
      JSON.parse(File.read(File.join(@destination, MANIFEST)))["version"]
    end

    def unmodified?
      manifest = JSON.parse(File.read(File.join(@destination, MANIFEST)))
      manifest.fetch("files") == digests(@destination)
    rescue Errno::ENOENT, JSON::ParserError, KeyError
      false
    end
  end
end
