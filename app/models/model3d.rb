class Model3d < ApplicationRecord
  belongs_to :designer
  has_many :model_files, -> { order(:position) }, dependent: :destroy
  has_many :license_offers, dependent: :destroy

  enum :status, %w[draft published retired].index_by(&:itself), default: "draft"

  validates :title, presence: true
  validates :slug, presence: true, uniqueness: true

  # Keyword search v1: ILIKE over title/tags/description, ranked
  # title > tag > description. Trigram/pgvector upgrades come later.
  def self.search(query)
    pattern = "%#{sanitize_sql_like(query.to_s.strip)}%"
    tag_match = "EXISTS (SELECT 1 FROM unnest(tags) tag WHERE tag ILIKE :pattern)"
    where("title ILIKE :pattern OR description ILIKE :pattern OR #{tag_match}", pattern: pattern)
      .order(Arel.sql(sanitize_sql_array([
        "CASE WHEN title ILIKE :pattern THEN 0 WHEN #{tag_match} THEN 1 ELSE 2 END, title",
        pattern: pattern
      ])))
  end

  def render_file
    model_files.detect { |f| f.kind == "render" }
  end

  def printable_files
    model_files.reject { |f| f.kind == "render" }
  end
end
