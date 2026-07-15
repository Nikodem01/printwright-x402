class Model3d < ApplicationRecord
  belongs_to :designer
  has_many :model_files, -> { order(:position) }, dependent: :destroy
  has_many :license_offers, dependent: :destroy

  enum :status, %w[draft published retired].index_by(&:itself), default: "draft"

  validates :title, presence: true
  validates :slug, presence: true, uniqueness: true

  # Keyword search v1: every term must match somewhere (title/tags/description);
  # ranked by how strongly terms hit (title 2pts, tag 1pt). Trigram/pgvector later.
  def self.search(query)
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

  def render_file
    model_files.detect { |f| f.kind == "render" }
  end

  def printable_files
    model_files.reject { |f| f.kind == "render" }
  end
end
