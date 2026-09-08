# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

class TestLoadOrder < Minitest::Test
  LIB_PATH = File.expand_path("../lib", __dir__)
  DATABASE_SETUP = <<~RUBY
    require "active_record"
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Schema.define do
      create_table(:parents) { |t| t.string :name }
      create_table(:children) { |t| t.integer :parent_id }
    end
    class Parent < ActiveRecord::Base
      has_many :children
    end
    class Child < ActiveRecord::Base
      belongs_to :parent
    end
    3.times { Parent.create!.children.create! }
    def load_children
      Parent.all.map { |parent| parent.children.to_a }
    end
  RUBY

  def run_ruby(source)
    Dir.mktmpdir("and_one_smoke") do |root|
      output, status = Open3.capture2e(
        { "RAILS_ENV" => "test", "GITHUB_ACTIONS" => nil },
        RbConfig.ruby, "-I", LIB_PATH, "-e", source, chdir: root
      )
      assert status.success?, output
      output
    end
  end

  def test_standalone_require
    run_ruby('require "and_one"; abort "unexpected scan" if AndOne.scanning?')
  end

  def test_plain_active_record_scan
    run_ruby(<<~RUBY)
      require "and_one"
      #{DATABASE_SETUP}
      AndOne.raise_on_detect = false
      detections = AndOne.scan { load_children }
      abort "missing N+1" unless detections.any? { |d| d.table_name == "children" && d.count == 3 }
      detections = AndOne.scan { Parent.preload(:children).map { |parent| parent.children.to_a } }
      abort "preload flagged" unless detections.empty?
    RUBY
  end

  def test_real_rails_boot_in_both_require_orders
    [%w[rails/all and_one], %w[and_one rails/all]].each do |requires|
      run_ruby(<<~RUBY)
        #{requires.map { |name| "require #{name.inspect}" }.join("\n")}
        class SmokeApp < Rails::Application
          config.root = Dir.pwd
          config.eager_load = false
          config.secret_key_base = "test" * 32
          config.logger = Logger.new(File::NULL)
          config.active_support.deprecation = :stderr
        end
        Rails.application.initialize!
        abort "disabled" unless AndOne.enabled?
        abort "missing test default" unless AndOne.raise_on_detect
        abort "missing middleware" unless Rails.application.middleware.any? { |m| m.klass == AndOne::Middleware }
        abort "missing job hook" unless ActiveJob::Base < AndOne::ActiveJobHook
      RUBY
    end
  end

  def test_real_rspec_expectations_in_both_require_orders
    [%w[rspec/core and_one/rspec], %w[and_one/rspec rspec/core]].each do |requires|
      run_ruby(<<~RUBY)
        #{requires.map { |name| "require #{name.inspect}" }.join("\n")}
        #{DATABASE_SETUP}
        AndOne.raise_on_detect = true
        AndOne.notifications_callback = ->(*) { raise "matcher reported" }
        RSpec.describe "AndOne integration" do
          it("detects N+1") { expect { load_children }.to cause_n_plus_one }
          it("accepts preload") do
            expect { Parent.preload(:children).map { |p| p.children.to_a } }.not_to cause_n_plus_one
          end
          it "provides real positive and negative failure messages" do
            expect { expect {}.to cause_n_plus_one }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /none were detected/)
            expect { expect { load_children }.not_to cause_n_plus_one }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /children/)
          end
          it "rejects nesting" do
            AndOne.scan do
              expect { expect { nil }.not_to cause_n_plus_one }.to raise_error(ArgumentError, /active scan/)
            end
          end
        end
        exit RSpec::Core::Runner.run([])
      RUBY
    end
  end
end
