class CatalogImport < ApplicationRecord
  belongs_to :designer
  has_many :models3d, dependent: :restrict_with_error

  enum :status, %w[active rolled_back].index_by(&:itself), default: "active"
end
