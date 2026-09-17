# frozen_string_literal: true

require "test_helper"
require "and_one/cli"
require "stringio"
require "open3"
require "rbconfig"

class TestCLI < Minitest::Test
  include AndOneTestHelper

  def setup
    super
    @root = Dir.mktmpdir("and_one_cli")
    @path = AndOne::Session.new(root: File.join(@root, "tmp/and_one/sessions"),
                                environment: "development", id: "default").path
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  def run_cli(*args)
    out = StringIO.new
    err = StringIO.new
    status = AndOne::CLI.run([*args, "--root", @root, "--environment", "development", "--session", "default", "--json"], out: out, err: err)
    [status, JSON.parse(status.zero? ? out.string : err.string)]
  end

  def record(path = @path)
    detection = AndOne::Detection.new(queries: ["SELECT * FROM posts WHERE author_id = 1", "SELECT * FROM posts WHERE author_id = 2"],
                                      raw_caller_strings: ["app/services/feed.rb:12:in 'call'"], count: 2)
    AndOne::Aggregate.new(path: path, strict: true).record(detection)
    detection
  end

  def test_missing_is_not_empty_and_does_not_create_directories
    status, result = run_cli("issues")
    assert_equal 3, status
    assert_equal "missing_session", result.dig("error", "code")
    refute File.exist?(File.join(@root, "tmp"))
  end

  def test_reads_redacted_findings_without_mutating_storage
    detection = record
    file = File.join(@path, "aggregate.json")
    before = File.binread(file)
    mtime = File.mtime(file)
    status, result = run_cli("issues")
    assert_equal 0, status
    assert_equal 1, result["schema_version"]
    assert_equal "ok", result.dig("storage", "status")
    assert_equal false, result["application_booted"]
    assert_equal detection.issue_id, result["findings"].first["issue_id"]
    refute_match(/author_id = [12]/, result["findings"].first["sample_query"])
    assert_equal before, File.binread(file)
    assert_equal mtime, File.mtime(file)
    status, result = run_cli("show", detection.issue_id)
    assert_equal 0, status
    assert_equal 1, result["findings"].size
    assert_equal 4, run_cli("show", "nonexistent").first
  end

  def test_empty_aggregate_is_a_success
    AndOne::Aggregate.new(path: @path, strict: true).reset!
    status, result = run_cli("issues")
    assert_equal 0, status
    assert_empty result["findings"]
  end

  def test_corrupt_invalid_and_oversized_storage_fail_without_leaking_contents
    FileUtils.mkdir_p(@path)
    ["private broken document", "[]", '{"bad":{}}', "x" * (AndOne::AggregateStore::FileStore::MAX_BYTES + 1)].each do |content|
      File.write(File.join(@path, "aggregate.json"), content)
      status, result = run_cli("issues")
      assert_equal 2, status
      assert_equal "storage_error", result.dig("error", "code")
      refute_includes JSON.generate(result), "private broken document"
      assert_equal content, File.read(File.join(@path, "aggregate.json"))
    end
  end

  def test_lists_sessions_and_supports_custom_paths
    record
    status, result = run_cli("sessions")
    assert_equal 0, status
    assert_equal @path, result["sessions"].first["path"]
    custom = File.join(@root, "custom")
    record(custom)
    status, result = run_cli("export", "--path", custom)
    assert_equal 0, status
    assert_nil result["session"]
    assert_equal custom, result.dig("storage", "path")
  end

  def test_resolve_filter_show_export_and_reopen
    detection = record
    status, result = run_cli("resolve", detection.issue_id, "--note", "Regression test passed", "--revision", "abc123")
    assert_equal 0, status
    row = result.fetch("findings").first
    assert_equal "resolved", row.fetch("status")
    assert_equal "Regression test passed", row.dig("resolution", "note")
    assert_equal "abc123", row.dig("resolution", "revision")
    assert_empty run_cli("issues").last.fetch("findings")
    %w[resolved all].each do |filter|
      assert_equal 1, run_cli("issues", "--status", filter).last.fetch("findings").size
    end
    assert_equal 1, run_cli("export").last.fetch("findings").size
    assert_equal "resolved", run_cli("show", detection.issue_id).last.fetch("findings").first.fetch("status")
    status, result = run_cli("reopen", detection.issue_id)
    assert_equal 0, status
    assert_equal "open", result.fetch("findings").first.fetch("status")
    assert_equal "manual", result.fetch("findings").first.fetch("reopen_reason")
    assert_equal 1, run_cli("issues").last.fetch("findings").size
  end

  def test_resolution_command_errors_do_not_create_or_destroy_evidence
    assert_equal 2, run_cli("resolve", "unknown").first
    assert_equal 3, run_cli("resolve", "unknown", "--note", "Verified").first
    assert_equal 3, run_cli("reopen", "unknown").first
    refute File.exist?(File.join(@root, "tmp"))
    detection = record
    file = File.join(@path, "aggregate.json")
    before = File.binread(file)
    assert_equal 4, run_cli("resolve", "unknown", "--note", "Verified").first
    assert_equal 4, run_cli("reopen", "unknown").first
    assert_equal 2, run_cli("resolve", detection.issue_id, "--note", "  ").first
    assert_equal before, File.binread(file)
    File.write(file, "corrupt")
    assert_equal 2, run_cli("resolve", detection.issue_id, "--note", "Verified").first
    assert_equal "corrupt", File.read(file)
  end

  def test_sorting_by_observed_cost_queries_and_occurrences
    unknown = record
    aggregate = AndOne::Aggregate.new(path: @path, strict: true)
    timed = [2, 3].map do |line|
      cost = AndOne::QueryCost.new
      line.times { cost.record(line == 2 ? 10.0 : 1.0) }
      detection = AndOne::Detection.new(queries: ["SELECT * FROM posts WHERE author_id = 1"],
                                        raw_caller_strings: ["app/services/feed.rb:#{line}:in 'call'"],
                                        count: line, query_cost: cost)
      aggregate.record(detection)
      detection
    end
    aggregate.record(timed.last)
    assert_equal([timed.first.issue_id, timed.last.issue_id, unknown.issue_id],
                 run_cli("issues").last.fetch("findings").map { |row| row.fetch("issue_id") })
    %w[queries occurrences].each do |sort|
      assert_equal timed.last.issue_id, run_cli("issues", "--sort", sort).last.fetch("findings").first.fetch("issue_id")
    end
  end

  def test_session_selection_does_not_mix_environments
    record
    out = StringIO.new
    err = StringIO.new
    status = AndOne::CLI.run(["issues", "--json", "--root", @root, "--environment", "test", "--session", "default"], out: out, err: err)
    assert_equal 3, status
    assert_equal "missing_session", JSON.parse(err.string).dig("error", "code")
  end

  def test_unreadable_storage_is_not_a_missing_or_empty_session
    skip "Permissions do not restrict root" if Process.uid.zero?
    record
    file = File.join(@path, "aggregate.json")
    File.chmod(0o000, file)
    status, result = run_cli("issues")
    assert_equal 2, status
    assert_equal "storage_error", result.dig("error", "code")
  ensure
    File.chmod(0o600, file) if file
  end

  def test_usage_errors
    assert_equal 2, run_cli("show").first
    assert_equal 2, run_cli("issues", "unexpected").first
    assert_equal 2, run_cli("issues", "--sort", "nope").first
    assert_equal 2, run_cli("unknown").first
  end

  def test_executable_does_not_boot_application
    FileUtils.mkdir_p(File.join(@root, "config"))
    File.write(File.join(@root, "config/environment.rb"), 'abort "application booted"')
    record
    gem_root = File.expand_path("..", __dir__)
    output, status = Open3.capture2e({ "RAILS_ENV" => "development", "AND_ONE_SESSION" => "default" },
                                     RbConfig.ruby, "-I", File.join(gem_root, "lib"), File.join(gem_root, "exe/and-one"),
                                     "issues", "--json", chdir: @root)
    assert status.success?, output
    assert_equal 1, JSON.parse(output)["findings"].size
  end

  def test_skill_install_check_and_protection
    status, result = run_cli("skill", "install", "--target", "pi")
    assert_equal 0, status
    destination = result.dig("skill", "path")
    assert_equal File.join(@root, ".pi/skills/and-one"), destination
    assert File.file?(File.join(destination, "SKILL.md"))
    assert_equal 0, run_cli("skill", "check", "--target", "pi").first
    File.write(File.join(destination, "SKILL.md"), "local change")
    assert_equal 5, run_cli("skill", "check", "--target", "pi").first
    assert_equal 5, run_cli("skill", "install", "--target", "pi").first
    assert_equal "local change", File.read(File.join(destination, "SKILL.md"))
    assert_equal 0, run_cli("skill", "install", "--target", "pi", "--force").first
    assert_equal 0, run_cli("skill", "check", "--target", "pi").first
  end

  def test_skill_updates_managed_content_but_protects_unmanaged_files
    assert_equal 5, run_cli("skill", "check").first
    assert_equal 0, run_cli("skill", "install").first
    destination = File.join(@root, ".agents/skills/and-one")
    skill = File.join(destination, "SKILL.md")
    File.write(skill, "previous bundled content")
    manifest = { version: "older", files: { "SKILL.md" => Digest::SHA256.file(skill).hexdigest } }
    File.write(File.join(destination, AndOne::SkillInstaller::MANIFEST), JSON.generate(manifest))
    assert_equal 5, run_cli("skill", "check").first
    assert_equal 0, run_cli("skill", "install").first
    assert_equal 0, run_cli("skill", "check").first
    File.write(File.join(destination, "local-notes.md"), "keep this")
    assert_equal 5, run_cli("skill", "install").first
    assert_equal "keep this", File.read(File.join(destination, "local-notes.md"))
  end

  def test_skill_refuses_symlink_destinations
    File.symlink(@aggregate_tmpdir, File.join(@root, ".agents"))
    status, result = run_cli("skill", "install", "--force")
    assert_equal 2, status
    assert_equal "unsafe_destination", result.dig("error", "code")
  end
end
