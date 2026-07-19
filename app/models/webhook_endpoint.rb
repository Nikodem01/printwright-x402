class WebhookEndpoint < ApplicationRecord
  EVENTS = %w[sale.completed].freeze

  belongs_to :designer
  has_many :webhook_deliveries, dependent: :nullify

  scope :active, -> { where(active: true) }

  validates :url, presence: true, uniqueness: { scope: :designer_id }
  validates :secret_ciphertext, presence: true
  validate :events_are_supported
  validate :url_is_safe_https

  private

  def events_are_supported
    errors.add(:events, "contains an unsupported event") unless events.present? && (events - EVENTS).empty?
  end

  def url_is_safe_https
    Webhooks::Target.validate_url!(url)
  rescue Webhooks::Target::Invalid => error
    errors.add(:url, error.message)
  end
end
