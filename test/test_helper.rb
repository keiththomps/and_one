# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "active_record"
require "active_support"
require "and_one"
require "minitest/autorun"

# Set up an in-memory SQLite database for testing
ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: ":memory:"
)

ActiveRecord::Schema.define do
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
    AndOne.min_n_queries = 2
    AndOne.notifications_callback = nil

    # Clear any leftover thread state
    Thread.current[:and_one_detector] = nil
    Thread.current[:and_one_paused] = false
  end

  def teardown
    super
    Thread.current[:and_one_detector] = nil
    Thread.current[:and_one_paused] = false
  end
end
