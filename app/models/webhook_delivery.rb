class WebhookDelivery < ApplicationRecord
  STATUSES = %w[pending delivered failed].freeze
  TARGET_KINDS = %w[designer buyer].freeze
  EVENT_TYPES = %w[sale.completed certificate.anchored].freeze

  belongs_to :webhook_endpoint, optional: true
  belongs_to :license

  enum :status, STATUSES.index_by(&:itself), default: "pending"

  validates :event_key, :event_id, :url, :secret_ciphertext, presence: true
  validates :event_key, uniqueness: true
  validates :target_kind, inclusion: { in: TARGET_KINDS }
  validates :event_type, inclusion: { in: EVENT_TYPES }
end
