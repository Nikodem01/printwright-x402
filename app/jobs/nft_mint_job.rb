# Mints the license as an HTS NFT and airdrops it to the buyer, after the HCS
# cert has anchored (the cert is the record; the NFT is the holdable proof —
# its metadata carries the cert id, chaining the two). Skips quietly when the
# buyer paid as an unidentified bearer: an airdrop needs a real account.
#
# Royalty design (V2 kill-test): one collection per designer, plain royalty
# (no fallback — fallback-royalty NFTs cannot be airdropped), collector =
# the designer's payout account when verified, else treasury custody.
class NftMintJob < ApplicationJob
  queue_as :default
  retry_on SidecarClient::Unavailable, wait: :polynomially_longer, attempts: 10

  ROYALTY_PERCENT = 10

  def perform(license_id)
    license = License.find(license_id)
    return if license.nft_serial.present? # idempotent — retries must not double-mint
    return unless license.anchored?

    buyer = license.purchase.buyer_hint.to_s
    return unless buyer.match?(/\A0\.0\.\d+\z/)
    # Self-airdrops are network-rejected (ACCOUNT_REPEATED_IN_ACCOUNT_AMOUNTS);
    # only happens when the operator buys from itself in a dev loop.
    return if buyer == ENV["HEDERA_ACCOUNT_ID"]

    designer = license.purchase.license_offer.model3d.designer
    collection = ensure_collection(designer)
    result = SidecarClient.new.mint_airdrop(
      token_id: collection,
      metadata: license.cert_id, # <= 100 bytes, resolvable via /verify/<cert_id>
      recipient: buyer
    )
    license.update!(
      nft_token_id: collection,
      nft_serial: result.fetch("serial"),
      nft_claim_state: result["pending"] ? "pending" : "claimed",
      nft_airdrop_tx_id: result["airdropTransactionId"]
    )
  end

  private

  def ensure_collection(designer)
    designer.with_lock do
      return designer.nft_collection_id if designer.nft_collection_id.present?

      collector = designer.payout_account_verified? ? designer.hedera_account_id : ENV.fetch("X402_PAY_TO")
      created = SidecarClient.new.create_collection(
        name: "Printwright Licenses — #{designer.display_name}".truncate(100),
        symbol: "PWL",
        royalty_collector: collector,
        royalty_percent: ROYALTY_PERCENT
      )
      designer.update!(nft_collection_id: created.fetch("tokenId"))
      designer.nft_collection_id
    end
  end
end
