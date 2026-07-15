class Model3d < ApplicationRecord
  belongs_to :designer
  has_many :model_files, -> { order(:position) }, dependent: :destroy
  has_many :license_offers, dependent: :destroy

  enum :status, %w[draft published retired].index_by(&:itself), default: "draft"

  validates :title, presence: true
  validates :slug, presence: true, uniqueness: true

  def render_file
    model_files.detect { |f| f.kind == "render" }
  end

  def printable_files
    model_files.reject { |f| f.kind == "render" }
  end
end
