class PurchaseBatch < ApplicationRecord
  STATUSES = %w[pending verified settled delivered failed_verification failed_settlement].freeze

  has_many :purchases, -> { order(:batch_position) }, dependent: :restrict_with_error

  enum :status, STATUSES.index_by(&:itself), default: "pending"

  validates :replay_key, presence: true, uniqueness: true
end
