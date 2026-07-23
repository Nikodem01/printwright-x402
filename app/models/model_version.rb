class ModelVersion < ApplicationRecord
  HASH_FORMAT = /\Asha256:[0-9a-f]{64}\z/
  FILE_KINDS = %w[stl 3mf step].freeze

  belongs_to :model3d
  has_one_attached :file

  validates :number, numericality: { only_integer: true, greater_than_or_equal_to: 2 },
    uniqueness: { scope: :model3d_id }
  validates :file_kind, inclusion: { in: FILE_KINDS }
  validates :file_hash, :changelog_hash, format: { with: HASH_FORMAT }
  validates :changelog, :published_at, presence: true

  # Buyers receive a version only once it is deliverable: it passed mesh
  # analysis, or its format cannot be mesh-validated (STEP) and was accepted
  # as today. A pending or failed STL/3MF version is withheld until it passes.
  scope :deliverable, -> { where(mesh_analysis_status: %w[passed skipped]) }

  def deliverable? = mesh_analysis_status.in?(%w[passed skipped])
  def mesh_failed? = mesh_analysis_status == "failed"
  def mesh_analysis_errors = Array(mesh_analysis["errors"])

  # Adapts this single-file version to the shape MeshAnalysis::Analyzer reads
  # from a ModelFile (it keys on `kind` and `file`).
  def analyzer_input = Struct.new(:kind, :file).new(file_kind, file)

  def anchored?
    hcs_sequence_number.present?
  end

  def anchor_payload
    {
      "schema" => "pwv-1",
      "model_id" => model3d_id,
      "version" => number,
      "original_hash" => model3d.file_hash,
      "file_hash" => file_hash,
      "changelog_hash" => changelog_hash,
      "published_at" => published_at.iso8601
    }
  end
end
