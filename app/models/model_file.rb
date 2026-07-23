class ModelFile < ApplicationRecord
  PRINTABLE_KINDS = %w[stl 3mf step].freeze
  KINDS = (PRINTABLE_KINDS + %w[render preview]).freeze

  belongs_to :model3d
  has_one_attached :file

  validates :kind, inclusion: { in: KINDS }

  def printable? = kind.in?(PRINTABLE_KINDS)
end
