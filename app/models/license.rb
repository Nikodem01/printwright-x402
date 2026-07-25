class License < ApplicationRecord
  class SoldOut < StandardError; end

  belongs_to :purchase
  has_one :license_offer, through: :purchase
  has_many :download_grants, dependent: :destroy
  has_one :print_report, dependent: :destroy
  has_one :library_membership, dependent: :destroy

  validates :serial, presence: true

  # Serial allocation must survive concurrent purchases of the same offer:
  # the row lock on the offer serializes counting, and max_units is enforced
  # inside the same critical section.
  def self.allocate!(purchase)
    offer = purchase.license_offer
    transaction do
      offer.lock!
      next_serial = joins(:purchase)
        .where(purchases: { license_offer_id: offer.id, sandbox: purchase.sandbox? })
        .maximum(:serial).to_i + 1
      raise SoldOut if !purchase.sandbox? && offer.max_units && next_serial > offer.max_units

      prefix = purchase.sandbox? ? "sandbox-pw" : "pw"
      # Unguessable public handles. Sequential slugs would let anyone walk
      # /verify/<n> or the certificates API and reveal every certificate,
      # defeating the commitment; a cert is disclosed only when its holder
      # shares the link. cert_salt is the off-chain salt for that commitment.
      create!(
        purchase: purchase,
        serial: next_serial,
        cert_id: "#{prefix}-#{SecureRandom.hex(12)}",
        verify_slug: SecureRandom.urlsafe_base64(16),
        cert_salt: SecureRandom.hex(32)
      )
    end
  end

  def anchored?
    hcs_sequence_number.present?
  end
end
