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
    max_units && purchases.where(sandbox: false).where.not(status: FAILED_STATUSES).count >= max_units
  end

  FAILED_STATUSES = %w[failed_verification failed_settlement].freeze

  before_save :compute_terms_hash,
    if: -> { new_record? || terms_version_changed? || terms_md_changed? }
  validate :terms_document_exists, if: :terms_version

  # The legal text this offer sells under: the canonical versioned document
  # when terms_version is set (the norm), else the designer's legacy terms_md.
  def terms_text
    terms_version ? Licensing::Documents.text(terms_version, kind) : terms_md
  end

  private

  # terms_hash is what certificates anchor. Canonical documents hash the
  # committed file bytes (recomputable from the /license permalink);
  # legacy free-text offers hash their own terms_md.
  def compute_terms_hash
    self.terms_hash =
      if terms_version
        Licensing::Documents.hash(terms_version, kind)
      else
        terms_md.nil? ? nil : "sha256:#{Digest::SHA256.hexdigest(terms_md)}"
      end
  end

  def terms_document_exists
    errors.add(:terms_version, "has no #{kind} document") unless Licensing::Documents.exists?(terms_version, kind)
  end
end
