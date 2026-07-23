class LicenseOffer < ApplicationRecord
  KINDS = %w[personal commercial_unit].freeze
  PRODUCTS = {
    "personal" => {
      name: "Personal use",
      summary: "The buyer may print unlimited copies for their own non-commercial use.",
      example: "Example: print one for a desk and another as a gift; do not sell the prints."
    },
    "commercial_unit" => {
      name: "Commercial per-unit",
      summary: "Each purchased unit licenses one physical print for commercial sale.",
      example: "Example: a shop selling 12 prints buys 12 licensed units; the digital files are never redistributed."
    }
  }.freeze

  belongs_to :model3d
  belongs_to :supersedes, class_name: "LicenseOffer", optional: true
  has_one :superseding_offer, class_name: "LicenseOffer", foreign_key: :supersedes_id,
    dependent: :restrict_with_error
  has_many :purchases, dependent: :restrict_with_error

  scope :active, -> { where(active: true) }

  validates :kind, inclusion: { in: KINDS }
  validates :price_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :currency, inclusion: { in: %w[USDC HBAR] }
  validates :revision, numericality: { only_integer: true, greater_than: 0 }
  validates :kind, uniqueness: { scope: :model3d_id, conditions: -> { active } }, if: :active?

  COMMERCIAL_IDENTITY_FIELDS = %w[kind price_cents currency max_units terms_version terms_md].freeze

  def self.product(kind)
    PRODUCTS.fetch(kind.to_s)
  end

  def self.usdc_to_cents(value)
    text = value.to_s.strip
    return if text.blank?

    cents = BigDecimal(text) * 100
    return unless cents.positive? && cents.frac.zero?

    cents.to_i
  rescue ArgumentError
    nil
  end

  def self.normalize_price_attributes(attributes)
    normalized = attributes.to_h.stringify_keys
    if normalized.key?("price_usdc")
      normalized["price_cents"] = usdc_to_cents(normalized.delete("price_usdc"))
    end
    normalized
  end

  def price_usdc
    return @price_usdc if defined?(@price_usdc)
    return if price_cents.nil?

    format("%.2f", price_cents / 100.0)
  end

  def price_usdc=(value)
    @price_usdc = value
    self.price_cents = self.class.usdc_to_cents(value)
  end

  # Capacity counts every purchase that may still turn into a license, not
  # just allocated licenses — so a unit can't be oversold while a payment is
  # in flight. Authoritative only under the offer row lock (see the download
  # controller's create step); unlocked callers get an advisory answer.
  def sold_out?
    max_units && units_remaining.zero?
  end

  def capacity_used
    purchases.where(sandbox: false).where.not(status: FAILED_STATUSES).count
  end

  def units_remaining
    max_units && [ max_units - capacity_used, 0 ].max
  end

  def commercial_identity_locked?
    purchases.where(sandbox: false).where.not(status: FAILED_STATUSES).exists?
  end

  # These terminal attempts can no longer become licenses and release their
  # reservation.
  FAILED_STATUSES = %w[failed_verification failed_settlement].freeze

  before_save :compute_terms_hash,
    if: -> { new_record? || kind_changed? || terms_version_changed? || terms_md_changed? }
  validate :terms_document_exists, if: :terms_version
  validate :commercial_identity_is_immutable_once_reserved, on: :update

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

  def commercial_identity_is_immutable_once_reserved
    return unless COMMERCIAL_IDENTITY_FIELDS.any? { |field| will_save_change_to_attribute?(field) }
    return unless commercial_identity_locked?

    errors.add(:base,
      "A reserved or sold offer is immutable; create a new offer revision for future buyers.")
  end
end
