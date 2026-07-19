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
