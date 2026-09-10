# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

class TestRailsConfiguration < Minitest::Test
  LIB_PATH = File.expand_path("../lib", __dir__)

  def boot(environment, initializer: "", before: "", assertions: "")
    Dir.mktmpdir("and_one_boot") do |root|
      FileUtils.mkdir_p(File.join(root, "config/initializers"))
      File.write(File.join(root, "config/initializers/and_one.rb"), initializer)
      source = <<~RUBY
        require "rails/all"
        require "and_one"
        #{before}
        class ConfigurationApp < Rails::Application
          config.root = Dir.pwd
          config.eager_load = false
          config.secret_key_base = "test" * 32
          config.logger = Logger.new(File::NULL)
          config.active_support.deprecation = :stderr
        end
        Rails.application.initialize!
        #{assertions}
      RUBY
      output, status = Open3.capture2e(
        { "RAILS_ENV" => environment, "GITHUB_ACTIONS" => nil },
        RbConfig.ruby, "-I", LIB_PATH, "-e", source, chdir: root
      )
      assert status.success?, output
    end
  end

  def test_environment_defaults
    %w[development test production].each do |environment|
      active = environment != "production"
      boot(environment, assertions: <<~RUBY)
        abort "enabled" unless AndOne.enabled? == #{active}
        abort "raise" unless AndOne.raise_on_detect == #{environment == "test"}
        abort "toast" unless AndOne.dev_toast == #{environment == "development"}
        abort "logfile" unless !!AndOne.logfile == #{active}
        abort "middleware" unless Rails.application.middleware.any? { |m| m.klass == AndOne::Middleware } == #{active}
        abort "unexpected storage" if !#{active} && File.exist?("tmp/and_one")
      RUBY
    end
  end

  def test_initializer_paths_and_format_are_used_before_io
    boot("test", initializer: <<~RUBY, assertions: <<~RUBY)
      abort "premature storage" if File.exist?("tmp/and_one")
      AndOne.aggregate_path = Rails.root.join("custom_aggregate").to_s
      AndOne.logfile = Rails.root.join("custom_logs/findings.jsonl").to_s
      AndOne.logfile_format = :json
      AndOne.raise_on_detect = false
    RUBY
      abort "default storage touched" if File.exist?("tmp/and_one")
      abort "custom storage unused" unless File.directory?("custom_aggregate")
      abort "raise overwritten" if AndOne.raise_on_detect
      detection = AndOne::Detection.new(queries: ["SELECT * FROM posts"], count: 2)
      AndOne.send(:report, [detection])
      entry = JSON.parse(File.read("custom_logs/findings.jsonl"))
      abort "wrong format" unless entry["event"] == "n_plus_one_detected"
      abort "default logfile touched" if File.exist?("log/and_one.log")
    RUBY
  end

  def test_explicit_disable_before_boot_and_in_initializer
    ["AndOne.logfile = nil", "AndOne.logfile = false"].each do |setting|
      boot("development", before: setting, assertions: 'abort "logfile enabled" if AndOne.logfile_writer')
      boot("test", initializer: setting, assertions: 'abort "logfile enabled" if AndOne.logfile_writer')
    end
    boot("test", initializer: "AndOne.enabled = false", assertions: <<~RUBY)
      abort "enabled" if AndOne.enabled?
      abort "storage touched" if File.exist?("tmp/and_one")
      abort "middleware installed" if Rails.application.middleware.any? { |m| m.klass == AndOne::Middleware }
    RUBY
    boot("test", before: "AndOne.enabled = false; AndOne.raise_on_detect = false", assertions: <<~RUBY)
      abort "overwritten" if AndOne.enabled? || AndOne.raise_on_detect
    RUBY
  end

  def test_toast_in_real_rails_middleware_stack
    boot("development", initializer: "AndOne.logfile = nil; Rails.application.config.hosts.clear",
                        before: 'ENV["DATABASE_URL"] = "sqlite3::memory:"', assertions: <<~RUBY)
                          class ToastController < ActionController::Base
                            def index
                              3.times do
                                ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT * FROM posts WHERE id = 1", name: "Post Load")
                              end
                              response.set_header("Content-Security-Policy", "default-src 'none'")
                              render html: "<html><body>Rails page</body></html>".html_safe
                            end
                          end
                          Rails.application.routes.draw { get "/toast", to: "toast#index" }
                          response = Rack::MockRequest.new(Rails.application).get("http://localhost/toast")
                          abort "status: \#{response.status} \#{response.body}" unless response.status == 200
                          abort "missing fallback" unless response.body.include?("<details>") && response.body.include?("posts")
                          abort "inline script" if response.body.include?("<script>")
                          abort "changed CSP" unless response["content-security-policy"] == "default-src 'none'"
                        RUBY
  end

  def test_explicit_production_enable
    boot("production", initializer: "AndOne.enabled = true; AndOne.raise_on_detect = true", assertions: <<~RUBY)
      abort "disabled" unless AndOne.enabled? && AndOne.raise_on_detect
      abort "missing middleware" unless Rails.application.middleware.any? { |m| m.klass == AndOne::Middleware }
    RUBY
  end
end
