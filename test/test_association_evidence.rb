# frozen_string_literal: true

require "test_helper"
require "zeitwerk"

class TestAssociationEvidence < Minitest::Test
  include AndOneTestHelper

  def setup
    super
    @constants = []
    connection = ActiveRecord::Base.connection
    connection.create_table(:advice_owners, force: true) { |t| t.string :code }
    connection.create_table(:advice_items, force: true) { |t| t.string :owner_code }
    connection.create_table(:advice_badges, force: true) { |t| t.integer :advice_owner_id }
    connection.create_table(:advice_notes, force: true) do |t|
      t.integer :notable_id
      t.string :notable_type
    end
    model(:AdviceOwner)
    model(:AdviceItem)
    model(:AdviceBadge)
    model(:AdviceNote)
    AdviceOwner.has_many :items, class_name: "AdviceItem", foreign_key: :owner_code, primary_key: :code
    AdviceItem.belongs_to :owner, class_name: "AdviceOwner", foreign_key: :owner_code, primary_key: :code
    AdviceOwner.has_one :badge, class_name: "AdviceBadge"
    AdviceBadge.belongs_to :advice_owner
    AdviceOwner.has_many :notes, as: :notable, class_name: "AdviceNote"
    AdviceNote.belongs_to :notable, polymorphic: true
    AdviceItem.has_many :notes, through: :owner
    AdviceItem.has_one :badge, through: :owner
    3.times do |i|
      owner = AdviceOwner.create!(code: "owner-#{i}")
      owner.items.create!
      owner.create_badge!
      owner.notes.create!
    end
  end

  def teardown
    @constants.each { |name| Object.send(:remove_const, name) if Object.const_defined?(name, false) }
    super
  end

  def test_belongs_to_direction
    suggestion = resolve('SELECT "authors".* FROM "authors" WHERE "authors"."id" = 1 LIMIT 1')

    assert_equal Post, suggestion.parent_model
    assert_equal :author, suggestion.association_name
    assert_includes suggestion.strict_loading_hint, "belongs_to :author"
  end

  def test_custom_keys_in_both_directions
    suggestion = scan_suggestion { AdviceOwner.all.each { |owner| owner.items.to_a } }
    assert_equal :items, suggestion.association_name
    assert_includes suggestion.strict_loading_hint, "has_many :items"

    suggestion = scan_suggestion { AdviceItem.all.each(&:owner) }
    assert_equal :owner, suggestion.association_name
    assert_includes suggestion.strict_loading_hint, "belongs_to :owner"
  end

  def test_has_one_declaration
    suggestion = scan_suggestion { AdviceOwner.all.each(&:badge) }
    assert_equal :badge, suggestion.association_name
    assert_includes suggestion.strict_loading_hint, "has_one :badge"
  end

  def test_two_associations_abstain
    AdviceOwner.has_many :other_items, class_name: "AdviceItem", foreign_key: :owner_code, primary_key: :code
    suggestion = scan_suggestion { AdviceOwner.all.each { |owner| owner.items.to_a } }

    refute suggestion.actionable?
    assert_nil suggestion.association_name
    assert_includes suggestion.fix_hint, "ambiguous"
  end

  def test_polymorphic_and_through_queries_abstain
    suggestion = scan_suggestion { AdviceOwner.all.each { |owner| owner.notes.to_a } }
    refute suggestion.actionable?
    suggestion = scan_suggestion { AdviceItem.all.each { |item| item.notes.to_a } }
    refute suggestion.actionable?
    suggestion = scan_suggestion { AdviceItem.all.each(&:badge) }
    refute suggestion.actionable?
  end

  def test_misses_are_not_cached_and_reloaded_classes_are_not_retained
    assert_nil AndOne::AssociationResolver.model_for_table("advice_late_models")
    original = model(:AdviceLateModel)
    assert_same original, AndOne::AssociationResolver.model_for_table("advice_late_models")
    Object.send(:remove_const, :AdviceLateModel)
    replacement = model(:AdviceLateModel)
    refute_same original, replacement
    assert_same replacement, AndOne::AssociationResolver.model_for_table("advice_late_models")
  end

  def test_zeitwerk_reload_replaces_resolved_classes
    Dir.mktmpdir("and_one_reload") do |directory|
      File.write(File.join(directory, "advice_reloaded.rb"), "class AdviceReloaded < ActiveRecord::Base; end")
      loader = Zeitwerk::Loader.new
      loader.push_dir(directory)
      loader.enable_reloading
      loader.setup
      original = AdviceReloaded
      assert_same original, AndOne::AssociationResolver.model_for_table("advice_reloadeds")
      loader.reload
      replacement = AdviceReloaded
      refute_same original, replacement
      assert_same replacement, AndOne::AssociationResolver.model_for_table("advice_reloadeds")
    ensure
      loader&.unload
      loader&.unregister
    end
  end

  def test_reflections_are_not_cached
    suggestion = scan_suggestion { AdviceOwner.all.each(&:badge) }
    assert_equal :badge, suggestion.association_name
    AdviceOwner.has_one :other_badge, class_name: "AdviceBadge"
    refute scan_suggestion { AdviceOwner.all.each(&:badge) }.actionable?
  end

  private

  def model(name)
    @constants << name unless @constants.include?(name)
    Object.const_set(name, Class.new(ActiveRecord::Base))
  end

  def resolve(sql)
    detection = AndOne::Detection.new(queries: [sql], count: 3, adapter: "SQLite")
    AndOne::AssociationResolver.resolve(detection, [])
  end

  def scan_suggestion(&)
    detections = AndOne.scan(&)
    refute_empty detections
    AndOne::AssociationResolver.resolve(detections.first, [])
  end
end
