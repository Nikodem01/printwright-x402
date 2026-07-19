require "net/http"

class License < ApplicationRecord
  class SoldOut < StandardError; end

  belongs_to :purchase
  has_one :license_offer, through: :purchase
  has_many :download_grants, dependent: :destroy
  has_one :print_report, dependent: :destroy

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

      license = create!(purchase: purchase, serial: next_serial)
      prefix = purchase.sandbox? ? "sandbox-pw" : "pw"
      license.update!(
        cert_id: format("#{prefix}-%06d", license.id),
        verify_slug: format("#{prefix}-%06d", license.id)
      )
      license
    end
  end

  def anchored?
    hcs_sequence_number.present?
  end

  # A pending airdrop becomes claimed the moment the buyer's wallet claims it
  # — an on-chain fact we learn lazily from the mirror when someone looks.
  def refresh_nft_claim_state!
    return nft_claim_state unless nft_claim_state == "pending"

    mirror = Hedera::Network.mirror_base
    owner = purchase.buyer_hint
    return nft_claim_state unless owner&.match?(/\A0\.0\.\d+\z/)

    response = Hedera::Network.get(
      URI("#{mirror}/api/v1/accounts/#{owner}/nfts?token.id=#{nft_token_id}&serialnumber=#{nft_serial}")
    )
    if response.code.to_i == 200 && JSON.parse(response.body)["nfts"].to_a.any?
      update!(nft_claim_state: "claimed")
    end
    nft_claim_state
  rescue Hedera::Network::Unavailable, JSON::ParserError
    nft_claim_state # mirror hiccup: stay pending, check again next view
  end
end
