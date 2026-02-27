# frozen_string_literal: true

# Require this file to auto-configure RSpec with AndOne matchers:
#
#   require "and_one/rspec"
#
# Then in your specs:
#
#   it "loads posts efficiently" do
#     expect { Post.includes(:comments).each { |p| p.comments.to_a } }.not_to cause_n_plus_one
#   end
#

require "and_one"

RSpec.configure do |config|
  config.include AndOne::RSpecHelper
end if defined?(RSpec)
