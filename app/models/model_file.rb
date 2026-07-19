class ModelFile < ApplicationRecord
  KINDS = %w[stl 3mf step render preview].freeze

  belongs_to :model3d
  has_one_attached :file

  validates :kind, inclusion: { in: KINDS }
end
