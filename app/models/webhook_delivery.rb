class WebhookDelivery < ApplicationRecord
  STATUSES = %w[pending delivered failed].freeze
  TARGET_KINDS = %w[designer buyer].freeze
  EVENT_TYPES = %w[sale.completed certificate.anchored webhook.test].freeze

  belongs_to :webhook_endpoint, optional: true
  # Optional only for webhook.test pings; every real event delivery sets one.
  belongs_to :license, optional: true

  enum :status, STATUSES.index_by(&:itself), default: "pending"

  validates :event_key, :event_id, :url, :secret_ciphertext, presence: true
  validates :event_key, uniqueness: true
  validates :target_kind, inclusion: { in: TARGET_KINDS }
  validates :event_type, inclusion: { in: EVENT_TYPES }
end
