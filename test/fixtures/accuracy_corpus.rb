# frozen_string_literal: true

# Small isolated schema: no generated Rails application and no adapter-specific SQL.
module AccuracyCorpus
  module_function

  def setup!
    connection = ActiveRecord::Base.connection
    connection.create_table(:corpus_owners, force: true) { |t| t.string :code }
    connection.create_table(:corpus_items, force: true) { |t| t.string :owner_code }
    connection.create_table(:corpus_badges, force: true) { |t| t.integer :corpus_owner_id }
    connection.create_table(:corpus_entries, force: true) do |t|
      t.integer :corpus_owner_id
      t.boolean :published
    end
    connection.create_table(:corpus_links, force: true) { |t| t.integer :corpus_owner_id }
    connection.create_table(:corpus_notes, force: true) do |t|
      t.integer :notable_id
      t.string :notable_type
    end
    %w[Owner Item Badge Entry Link Note].each do |name|
      Object.const_set("Corpus#{name}", Class.new(ActiveRecord::Base))
    end
    CorpusOwner.has_many :items, class_name: "CorpusItem", foreign_key: :owner_code, primary_key: :code
    CorpusItem.belongs_to :owner, class_name: "CorpusOwner", foreign_key: :owner_code, primary_key: :code
    CorpusOwner.has_one :badge, class_name: "CorpusBadge"
    CorpusOwner.has_many :published_entries, -> { where(published: true) }, class_name: "CorpusEntry"
    CorpusOwner.has_many :links, class_name: "CorpusLink"
    CorpusOwner.has_many :other_links, class_name: "CorpusLink"
    CorpusOwner.has_many :notes, as: :notable, class_name: "CorpusNote"
    CorpusNote.belongs_to :notable, polymorphic: true
    CorpusItem.has_many :notes, through: :owner
    3.times do |index|
      owner = CorpusOwner.create!(code: "owner-#{index}")
      2.times { owner.items.create! }
      owner.create_badge!
      owner.published_entries.create!
      CorpusEntry.create!(corpus_owner_id: owner.id, published: false)
      owner.links.create!
      owner.notes.create!
    end
    # Warm schema/type metadata outside both SQL capture and count measurement.
    [CorpusOwner, CorpusItem, CorpusBadge, CorpusEntry, CorpusLink, CorpusNote].each(&:columns)
  end

  def teardown!
    %w[Owner Item Badge Entry Link Note].each { |name| Object.send(:remove_const, "Corpus#{name}") }
  end

  # truth describes the workload; observed describes today's repeated-shape
  # detector, NOT a claim that duplicate reads/batching are association N+1s.
  def scenarios
    [
      { name: :has_many, truth: :association_n_plus_one, observed: :candidate,
        model: -> { Post }, association: :comments },
      { name: :belongs_to, truth: :association_n_plus_one, observed: :candidate,
        model: -> { Post }, association: :author },
      { name: :has_many_custom_key, truth: :association_n_plus_one, observed: :candidate,
        model: -> { CorpusOwner }, association: :items },
      { name: :belongs_to_custom_key, truth: :association_n_plus_one, observed: :candidate,
        model: -> { CorpusItem }, association: :owner },
      { name: :has_one, truth: :association_n_plus_one, observed: :candidate,
        model: -> { CorpusOwner }, association: :badge },
      { name: :scoped_association, truth: :association_n_plus_one, observed: :candidate,
        model: -> { CorpusOwner }, association: :published_entries },
      { name: :same_table_ambiguity, truth: :association_n_plus_one, observed: :guidance_only,
        model: -> { CorpusOwner }, association: :links, limitation: "two matching associations: exact advice unsupported" },
      { name: :polymorphic, truth: :association_n_plus_one, observed: :guidance_only,
        model: -> { CorpusOwner }, association: :notes, limitation: "polymorphic exact advice unsupported" },
      { name: :through, truth: :association_n_plus_one, observed: :guidance_only,
        model: -> { CorpusItem }, association: :notes, limitation: "through exact advice unsupported" },
      { name: :count, truth: :repeated_aggregate, observed: :guidance_only, operation: :count,
        workload: -> { CorpusOwner.order(:id).map { |owner| owner.items.count } } },
      { name: :exists, truth: :repeated_existence, observed: :guidance_only, operation: :exists,
        workload: -> { CorpusOwner.order(:id).map { |owner| owner.items.exists? } } },
      { name: :scalar, truth: :repeated_scalar, observed: :guidance_only, operation: :scalar,
        workload: -> { CorpusOwner.order(:id).map { |owner| owner.items.pluck(:id) } } },
      { name: :identical_lookup, truth: :duplicate_read, observed: :guidance_only, kind: :duplicate_identical_read,
        limitation: "identical reads are distinguished without proving caching is safe",
        workload: -> { 3.times.map { CorpusOwner.find_by!(code: "owner-0").id } } },
      { name: :intentional_batches, truth: :intentional_repetition, observed: :guidance_only,
        limitation: "known false positive: deliberate batching still triggers repeated-shape detection",
        workload: -> { CorpusItem.in_batches(of: 2).map { |batch| batch.pluck(:id) } } },
      { name: :query_cache, truth: :cached_duplicate_read, observed: :none,
        workload: -> { CorpusOwner.cache { 3.times.map { CorpusOwner.find_by!(code: "owner-0").id } } }, physical: 1 },
      { name: :preloaded, truth: :bounded_loading, observed: :none,
        workload: -> { records(CorpusOwner.preload(:items), :items) }, physical: 2 },
      { name: :below_threshold, truth: :association_n_plus_one, observed: :none,
        limitation: "known false negative by configured threshold: only one child query",
        workload: -> { records(CorpusOwner.limit(1), :items) }, physical: 2 }
    ]
  end

  def records(relation, association)
    relation.order(:id).map do |record|
      value = record.public_send(association)
      value.respond_to?(:to_ary) ? value.to_a.map(&:id).sort : value&.id
    end
  end
end
