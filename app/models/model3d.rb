class Model3d < ApplicationRecord
  belongs_to :designer
  has_many :model_files, -> { order(:position) }, dependent: :destroy
  # Personal is the storefront default; keep preload/query order deterministic
  # so a commercial offer cannot become checked merely because PostgreSQL
  # returned rows in a different physical order.
  has_many :license_offers, -> { order(kind: :desc, id: :asc) }, dependent: :destroy
  accepts_nested_attributes_for :license_offers, allow_destroy: true,
                                reject_if: ->(attrs) { attrs["price_cents"].blank? }
  has_neighbors :embedding

  enum :status, %w[draft published retired].index_by(&:itself), default: "draft"

  validates :title, presence: true
  validates :slug, presence: true, uniqueness: true

  after_commit :enqueue_embedding, on: %i[create update]

  # Cosine distance beyond which a match is considered noise rather than
  # signal, so a nonsense query returns nothing instead of the catalog's
  # least-bad model. Chosen from real gemini-embedding-001 distances measured
  # against the seeded catalog: genuine intent-query top hits landed
  # 0.25-0.41, while gibberish queries' *closest* model never landed below
  # 0.45 — 0.42 sits in that gap (see V29 report for the full measurements).
  SEMANTIC_DISTANCE_THRESHOLD = 0.42

  # Keyword search v3: exact pass (every term matches somewhere, ranked by
  # match strength), then a semantic (embedding) pass when nothing matched
  # and embeddings are available, then a pg_trgm similarity pass as the final
  # fallback — for typos, and for when embeddings are unavailable.
  def self.search(query)
    exact = exact_search(query)
    return exact if exact.any?

    semantic = semantic_search(query)
    return semantic if semantic.any?

    fuzzy_search(query)
  end

  def self.exact_search(query)
    terms = query.to_s.split.map { |t| "%#{sanitize_sql_like(t)}%" }
    return none if terms.empty?

    tag_match = "EXISTS (SELECT 1 FROM unnest(tags) tag WHERE tag ILIKE ?)"
    scope = terms.reduce(all) do |relation, pattern|
      relation.where(
        sanitize_sql_array([ "title ILIKE ? OR description ILIKE ? OR #{tag_match}", pattern, pattern, pattern ])
      )
    end
    rank = terms.map do |pattern|
      sanitize_sql_array([ "(CASE WHEN title ILIKE ? THEN 2 WHEN #{tag_match} THEN 1 ELSE 0 END)", pattern, pattern ])
    end.join(" + ")
    scope.order(Arel.sql("(#{rank}) DESC, title"))
  end

  def self.fuzzy_search(query)
    q = query.to_s.strip
    return none if q.blank?

    tag_sim = "(SELECT COALESCE(MAX(similarity(tag, ?)), 0) FROM unnest(tags) tag)"
    score = sanitize_sql_array([ "GREATEST(similarity(title, ?), #{tag_sim})", q, q ])
    where(Arel.sql("#{score} > 0.25")).order(Arel.sql("#{score} DESC, title"))
  end

  # Nearest-neighbour pass over Model3d#embedding. Query embeddings are
  # cached briefly so repeat searches don't re-bill the provider; a nil
  # embedder result (no key, network hiccup) degrades to `none` so the
  # caller falls through to fuzzy_search.
  def self.semantic_search(query)
    embedder = Search::Embedder.new
    return none unless embedder.available?

    q = query.to_s.strip
    return none if q.blank?

    vector = Rails.cache.fetch([ "model3d-search-embedding", q ], expires_in: 5.minutes) { embedder.embed(q) }
    return none if vector.nil?

    nearest_neighbors(:embedding, vector, distance: "cosine", threshold: SEMANTIC_DISTANCE_THRESHOLD)
  end

  # The model's searchable identity fed to Search::Embedder — one method so
  # re-embedding is deterministic and testable (EmbedModelJob, search:reindex).
  def searchable_text
    [ title, description, tags.join(" ") ].reject(&:blank?).join("\n")
  end

  def render_file
    model_files.detect { |f| f.kind == "render" }
  end

  def preview_file
    model_files.detect { |f| f.kind == "preview" }
  end

  def printable_files
    model_files.select { |f| %w[stl 3mf step].include?(f.kind) }
  end

  private

  # New and edited models get embeddings without a manual step — but only
  # when the text that feeds the embedding actually changed, so an unrelated
  # save (e.g. status flip) doesn't burn an API call.
  def enqueue_embedding
    return unless saved_change_to_title? || saved_change_to_description? || saved_change_to_tags?

    EmbedModelJob.perform_later(id)
  end
end
