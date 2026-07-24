# One file of a ModelVersion's printable bundle. Shaped exactly like
# ModelFile (kind + has_one_attached :file) so MeshAnalysis::Analyzer, which
# reads that shape, can analyze a whole version bundle unchanged.
class ModelVersionFile < ApplicationRecord
  belongs_to :model_version
  has_one_attached :file

  validates :kind, inclusion: { in: ModelVersion::FILE_KINDS }
  validates :file_hash, format: { with: ModelVersion::HASH_FORMAT }

  scope :ordered, -> { order(:position) }
end
