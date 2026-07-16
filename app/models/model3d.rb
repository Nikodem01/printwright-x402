class Model3d < ApplicationRecord
  belongs_to :designer
  has_many :model_files, -> { order(:position) }, dependent: :destroy
  has_many :license_offers, dependent: :destroy
  accepts_nested_attributes_for :license_offers, allow_destroy: true,
                                reject_if: ->(attrs) { attrs["price_cents"].blank? }

  enum :status, %w[draft published retired].index_by(&:itself), default: "draft"

  validates :title, presence: true
  validates :slug, presence: true, uniqueness: true

  # Keyword search v2: exact pass (every term matches somewhere, ranked by
  # match strength), then a pg_trgm similarity pass when nothing matched —
  # so misspellings ("beavr") still find the model. pgvector was unavailable
  # in the target Postgres; trigram is the graceful degradation (plan D6).
  def self.search(query)
    exact = exact_search(query)
    exact.any? ? exact : fuzzy_search(query)
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

  def render_file
    model_files.detect { |f| f.kind == "render" }
  end

  def printable_files
    model_files.reject { |f| f.kind == "render" }
  end
end
