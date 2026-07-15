class License < ApplicationRecord
  class SoldOut < StandardError; end

  belongs_to :purchase
  has_one :license_offer, through: :purchase
  has_many :download_grants, dependent: :destroy

  validates :serial, presence: true

  # Serial allocation must survive concurrent purchases of the same offer:
  # the row lock on the offer serializes counting, and max_units is enforced
  # inside the same critical section.
  def self.allocate!(purchase)
    offer = purchase.license_offer
    transaction do
      offer.lock!
      next_serial = joins(:purchase)
        .where(purchases: { license_offer_id: offer.id })
        .maximum(:serial).to_i + 1
      raise SoldOut if offer.max_units && next_serial > offer.max_units

      license = create!(purchase: purchase, serial: next_serial)
      license.update!(
        cert_id: format("pw-%06d", license.id),
        verify_slug: format("pw-%06d", license.id)
      )
      license
    end
  end

  def anchored?
    hcs_sequence_number.present?
  end
end
