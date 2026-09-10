# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

class TestSessions < Minitest::Test
  include AndOneTestHelper

  def boot(environment, id: nil)
    source = <<~RUBY
      require "rails/all"
      require "and_one"
      class SessionApp < Rails::Application
        config.root = Dir.pwd
        config.eager_load = false
        config.secret_key_base = "test" * 32
        config.logger = Logger.new(File::NULL)
        config.active_support.deprecation = :stderr
      end
      AndOne.aggregate_store = :file
      Rails.application.initialize!
      detection = AndOne::Detection.new(queries: ["SELECT * FROM posts"], count: 2)
      AndOne.aggregate.record(detection)
      AndOne.logfile_writer.record([detection])
      AndOne.logfile_writer.flush!
      puts JSON.generate(path: AndOne.session.path, logfile: AndOne.logfile,
                         occurrences: AndOne.aggregate.detections.values.first.occurrences)
    RUBY
    output, status = Open3.capture2e({ "RAILS_ENV" => environment, "AND_ONE_SESSION" => id },
                                     RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", source,
                                     chdir: @aggregate_tmpdir)
    assert status.success?, output
    JSON.parse(output.lines.last)
  end

  def test_independent_rails_boots_join_development_without_clearing_either_sink
    first = boot("development")
    before = File.read(first.fetch("logfile"))
    second = boot("development")
    assert_equal first.fetch("path"), second.fetch("path")
    assert_equal 2, second.fetch("occurrences")
    assert_equal before * 2, File.read(second.fetch("logfile"))
    assert_equal 0o600, File.stat(second.fetch("logfile")).mode & 0o777 unless Gem.win_platform?
  end

  def test_test_runs_and_environments_are_isolated_but_explicit_workers_can_join
    first = boot("test")
    second = boot("test")
    refute_equal first.fetch("path"), second.fetch("path")
    assert_equal 1, second.fetch("occurrences")
    shared = boot("test", id: "ci-run-123")
    assert_equal 2, boot("test", id: "ci-run-123").fetch("occurrences")
    dev = boot("development", id: "ci-run-123")
    refute_equal shared.fetch("path"), dev.fetch("path")
    assert_equal 1, dev.fetch("occurrences")
  end

  def session(id)
    AndOne::Session.new(root: File.join(@aggregate_tmpdir, "sessions"), environment: "test", id: id)
  end

  def test_preloaded_workers_inherit_identity_and_live_lease
    skip "fork unavailable" unless Process.respond_to?(:fork)

    active = session(AndOne::Session.default_id("test"))
    path = active.activate!
    pid = fork do
      fresh = session(AndOne::Session.default_id("test"))
      exit! 1 unless fresh.path == path
      AndOne::Aggregate.new(path: fresh.activate!, strict: true).record(
        AndOne::Detection.new(queries: ["SELECT * FROM posts"], count: 2)
      )
      exit! 0
    end
    assert Process.wait2(pid).last.success?
    assert_equal 1, AndOne::Aggregate.new(path: path).size
    age_session(path)
    assert_equal 0, session("maintenance").cleanup!(older_than: 1)
    assert File.directory?(path)
  end

  def age_session(path)
    ([path] + Dir.glob(File.join(path, "*"))).each { |file| File.utime(Time.at(0), Time.at(0), file) }
  end

  def test_bounded_cleanup_removes_only_stale_unleased_sessions
    old = session("old")
    FileUtils.mkdir_p(old.path)
    File.write(File.join(old.path, "session.lock"), "")
    age_session(old.path)
    recent = session("recent")
    FileUtils.mkdir_p(recent.path)
    File.write(File.join(recent.path, "session.lock"), "")
    active = session("active")
    active.activate!
    age_session(active.path)
    maintenance = session("maintenance")
    assert_operator maintenance.cleanup!(older_than: 1, limit: 1), :<=, 1
    maintenance.cleanup!(older_than: 1)
    refute File.exist?(old.path)
    assert File.exist?(recent.path)
    assert File.exist?(active.path)
  end

  def test_reset_affects_only_configured_session
    other = AndOne::Aggregate.new(path: session("other").activate!)
    detection = AndOne::Detection.new(queries: ["SELECT * FROM posts"], count: 2)
    other.record(detection)
    AndOne.aggregate.record(detection)
    AndOne.logfile = File.join(@aggregate_tmpdir, "findings.log")
    AndOne.logfile_writer.record([detection])
    AndOne.reset_session!
    assert AndOne.aggregate.empty?
    assert_equal "", File.read(AndOne.logfile)
    assert_equal 1, other.size
  end
end
