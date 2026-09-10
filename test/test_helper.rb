# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "logger" # Rails 7.0 expects Logger to be loaded before ActiveSupport.
require "active_record"
require "active_support"
require "and_one"
require "minitest/autorun"
require "tmpdir"
require "fileutils"

# Service-backed jobs run the portable integration corpus only. DATABASE_URL
# must point at a disposable test database: schema setup is destructive.
ActiveRecord::Base.establish_connection(
  ENV.fetch("DATABASE_URL") { { adapter: "sqlite3", database: ":memory:", prepared_statements: true } }
)

ActiveRecord::Schema.define do
  # Drop dependents first so service databases can be reused for another run.
  drop_table :comments, if_exists: true
  drop_table :posts, if_exists: true
  drop_table :authors, if_exists: true

  create_table :authors, force: true do |t|
    t.string :name
  end

  create_table :posts, force: true do |t|
    t.string :title
    t.references :author, foreign_key: true
  end

  create_table :comments, force: true do |t|
    t.string :body
    t.references :post, foreign_key: true
  end
end

class Author < ActiveRecord::Base
  has_many :posts
end

class Post < ActiveRecord::Base
  belongs_to :author
  has_many :comments
end

class Comment < ActiveRecord::Base
  belongs_to :post
end

# Seed helper
def seed_data!
  3.times do |i|
    author = Author.create!(name: "Author #{i}")
    3.times do |j|
      post = Post.create!(title: "Post #{i}-#{j}", author: author)
      2.times do |k|
        Comment.create!(body: "Comment #{i}-#{j}-#{k}", post: post)
      end
    end
  end
end

# Reset AndOne state between tests
module AndOneTestHelper
  def setup
    super
    AndOne.enabled = true
    AndOne.raise_on_detect = false
    AndOne.allow_stack_paths = []
    AndOne.ignore_queries = []
    AndOne.ignore_callers = []
    AndOne.min_n_queries = 2
    AndOne.notifications_callback = nil
    AndOne.json_logging = false
    AndOne.env_thresholds = nil
    AndOne.dev_toast = false
    AndOne.dev_toast_position = nil
    AndOne.logfile = nil
    AndOne.logfile_format = nil
    AndOne.ignore_file_path = nil
    AndOne.reload_ignore_file!
    @aggregate_tmpdir = Dir.mktmpdir("and_one_test")
    AndOne.aggregate_path = @aggregate_tmpdir
    AndOne.instance_variable_set(:@aggregate, nil)
    AndOne.instance_variable_set(:@logfile_writer, nil)

    # Clear any leftover thread state
    Thread.current[:and_one_detector] = nil
    Thread.current[:and_one_paused] = false
  end

  def teardown
    super
    Thread.current[:and_one_detector] = nil
    Thread.current[:and_one_paused] = false
    FileUtils.rm_rf(@aggregate_tmpdir) if @aggregate_tmpdir
  end
end
