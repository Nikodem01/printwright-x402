class LicenseOffer < ApplicationRecord
  KINDS = %w[personal commercial_unit].freeze

  belongs_to :model3d
  has_many :purchases, dependent: :restrict_with_error

  validates :kind, inclusion: { in: KINDS }
  validates :price_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :currency, inclusion: { in: %w[USDC HBAR] }

  # Capacity counts every purchase that may still turn into a license, not
  # just allocated licenses — so a unit can't be oversold while a payment is
  # in flight. Authoritative only under the offer row lock (see the download
  # controller's create step); unlocked callers get an advisory answer.
  def sold_out?
    max_units && purchases.where.not(status: FAILED_STATUSES).count >= max_units
  end

  FAILED_STATUSES = %w[failed_verification failed_settlement].freeze

  before_save :compute_terms_hash, if: :terms_md_changed?

  private

  def compute_terms_hash
    self.terms_hash = terms_md.nil? ? nil : "sha256:#{Digest::SHA256.hexdigest(terms_md)}"
  end
end
