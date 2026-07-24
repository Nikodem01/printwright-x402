class ModelVersion < ApplicationRecord
  HASH_FORMAT = /\Asha256:[0-9a-f]{64}\z/
  FILE_KINDS = %w[stl 3mf step].freeze

  belongs_to :model3d
  has_one_attached :file
  has_many :version_files, class_name: "ModelVersionFile", dependent: :destroy

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

  # The ordered printable bundle for this version; bundle_files.first is the
  # primary file mirrored by `file`/`file_kind`/`file_hash`. Every version has
  # at least one: the controller creates it on upload, and a migration
  # backfilled one for versions that predate multi-file bundles.
  def bundle_files = version_files.ordered

  # Adapts this single-file version to the shape MeshAnalysis::Analyzer reads
  # from a ModelFile (it keys on `kind` and `file`). Kept for backward safety
  # alongside `analyzer_inputs` below.
  def analyzer_input = Struct.new(:kind, :file).new(file_kind, file)

  # The version_files already have that shape, so the whole bundle can be
  # analyzed together.
  def analyzer_inputs = version_files.ordered

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
      "published_at" => published_at.iso8601,
      "files" => version_files.ordered.map { |f| { "kind" => f.kind, "hash" => f.file_hash } }
    }
  end
end
