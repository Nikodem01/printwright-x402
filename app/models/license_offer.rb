class LicenseOffer < ApplicationRecord
  KINDS = %w[personal commercial_unit].freeze

  belongs_to :model3d
  has_many :purchases, dependent: :restrict_with_error

  validates :kind, inclusion: { in: KINDS }
  validates :price_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :currency, inclusion: { in: %w[USDC HBAR] }

  before_save :compute_terms_hash, if: :terms_md_changed?

  private

  def compute_terms_hash
    self.terms_hash = terms_md.nil? ? nil : "sha256:#{Digest::SHA256.hexdigest(terms_md)}"
  end
end
