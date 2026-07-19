require "test_helper"
require "webmock/minitest"

class NftMintJobTest < ActiveSupport::TestCase
  SIDECAR = "http://localhost:4021".freeze

  setup do
    ENV["X402_PAY_TO"] = "0.0.9584959"
    ENV["SIDECAR_TOKEN"] = "test-token"
    @designer = designers(:one)
    model = Model3d.create!(designer: @designer, title: "NFT", slug: "nft-#{SecureRandom.hex(4)}")
    offer = model.license_offers.create!(kind: "personal", price_cents: 250)
    purchase = Purchase.create!(
      license_offer: offer, status: "settled", buyer_hint: "0.0.9613501",
      asset: "0.0.429274", amount_base_units: "250000",
      payment_tx_id: "0.0.7162784@1.2", replay_key: SecureRandom.hex(32)
    )
    @license = License.allocate!(purchase)
    @license.update!(cert_json: { "v" => 1 }, hcs_topic_id: "0.0.9585069", hcs_sequence_number: 42)
  end

  def stub_collection(token_id: "0.0.777")
    stub_request(:post, "#{SIDECAR}/create-collection")
      .to_return(body: { tokenId: token_id, transactionId: "0.0.1@7.7" }.to_json,
                 headers: { "content-type" => "application/json" })
  end

  def stub_mint(pending: true)
    stub_request(:post, "#{SIDECAR}/mint-airdrop")
      .to_return(body: { serial: 5, airdropTransactionId: "0.0.1@9.9", pending: pending }.to_json,
                 headers: { "content-type" => "application/json" })
  end

  test "creates the designer collection once, mints, and records the pending airdrop" do
    collection = stub_collection
    mint = stub_mint(pending: true)

    NftMintJob.perform_now(@license.id)
    @license.reload
    assert_equal [ "0.0.777", 5, "pending", "0.0.1@9.9" ],
      [ @license.nft_token_id, @license.nft_serial, @license.nft_claim_state, @license.nft_airdrop_tx_id ]
    assert_equal "0.0.777", @designer.reload.nft_collection_id

    # second license reuses the collection; job is idempotent per license
    NftMintJob.perform_now(@license.id)
    assert_requested collection, times: 1
    assert_requested mint, times: 1
  end

  test "concurrent licenses share one locked designer collection" do
    second_purchase = @license.purchase.dup
    second_purchase.replay_key = SecureRandom.hex(32)
    second_purchase.payment_tx_id = "0.0.7162784@2.3"
    second_purchase.save!
    second_license = License.allocate!(second_purchase)
    second_license.update!(
      cert_json: { "v" => 1 }, hcs_topic_id: "0.0.9585069", hcs_sequence_number: 43
    )
    collection = stub_request(:post, "#{SIDECAR}/create-collection").to_return do
      sleep 0.1
      { body: { tokenId: "0.0.777", transactionId: "0.0.1@7.7" }.to_json,
        headers: { "content-type" => "application/json" } }
    end
    serial = 0
    serial_lock = Mutex.new
    stub_request(:post, "#{SIDECAR}/mint-airdrop").to_return do
      next_serial = serial_lock.synchronize { serial += 1 }
      { body: { serial: next_serial, airdropTransactionId: "0.0.1@9.#{next_serial}", pending: true }.to_json,
        headers: { "content-type" => "application/json" } }
    end

    errors = [ @license.id, second_license.id ].map do |license_id|
      Thread.new { NftMintJob.perform_now(license_id) }
    end.map { |thread| thread.value rescue $ERROR_INFO }.select { |result| result.is_a?(Exception) }

    assert_empty errors
    assert_requested collection, times: 1
    assert_equal [ "0.0.777" ], License.where(id: [ @license.id, second_license.id ]).distinct.pluck(:nft_token_id)
  end

  test "unverified designer's collection routes royalties to treasury; verified to the designer" do
    stub_mint
    treasury_stub = stub_request(:post, "#{SIDECAR}/create-collection")
      .with { |req| JSON.parse(req.body)["royaltyCollector"] == "0.0.9584959" }
      .to_return(body: { tokenId: "0.0.777", transactionId: "0.0.1@7.7" }.to_json,
                 headers: { "content-type" => "application/json" })
    NftMintJob.perform_now(@license.id)
    assert_requested treasury_stub, times: 1

    @designer.reload.update!(nft_collection_id: nil, hedera_account_id: "0.0.9604186")
    @designer.update!(payout_account_verified_at: Time.current)
    @license.reload.update!(nft_serial: nil, nft_token_id: nil)
    designer_stub = stub_request(:post, "#{SIDECAR}/create-collection")
      .with { |req| JSON.parse(req.body)["royaltyCollector"] == "0.0.9604186" }
      .to_return(body: { tokenId: "0.0.888", transactionId: "0.0.1@7.8" }.to_json,
                 headers: { "content-type" => "application/json" })
    NftMintJob.perform_now(@license.id)
    assert_requested designer_stub, times: 1
  end

  test "bearer purchases and unanchored certs skip quietly" do
    @license.purchase.update!(buyer_hint: "bearer")
    NftMintJob.perform_now(@license.id)
    assert_nil @license.reload.nft_serial

    @license.purchase.update!(buyer_hint: "0.0.9613501")
    @license.update!(hcs_sequence_number: nil)
    NftMintJob.perform_now(@license.id)
    assert_nil @license.reload.nft_serial
  end
end
