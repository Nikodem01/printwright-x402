require "test_helper"

class Chat::PurchaseIntentTest < ActiveSupport::TestCase
  setup do
    @model = Model3d.create!(
      designer: designers(:one), title: "Intent Clip", slug: "intent-clip-#{SecureRandom.hex(4)}",
      status: "published", file_hash: "sha256:#{'b' * 64}"
    )
    @offer = @model.license_offers.create!(kind: "personal", price_cents: 90, terms_md: "T.")
    @conversation = ChatConversation.create!(purchase_proposal: approved_proposal)
    @token = Chat::PurchaseIntent.issue(conversation: @conversation, proposal: approved_proposal)
    @matched = { asset: X402::Requirements.usdc_asset, amount: "900000" }
  end

  test "intent binds one transaction to the approved conversation, route, offer, and amount" do
    context = authorize(transaction: "signed-transaction-a")

    stored = @conversation.reload.purchase_proposal
    assert_equal "submitting", stored["state"]
    assert_equal Digest::SHA256.hexdigest("signed-transaction-a"), stored["transaction_digest"]

    assert_equal context, authorize(transaction: "signed-transaction-a")
    error = assert_raises(Chat::PurchaseIntent::Invalid) { authorize(transaction: "signed-transaction-b") }
    assert_equal "payment_intent_replayed", error.code

    Chat::PurchaseIntent.complete!(context)
    assert_equal "completed", @conversation.reload.purchase_proposal["state"]
  end

  test "tampered route, amount, and token are rejected without claiming the proposal" do
    assert_raises(Chat::PurchaseIntent::Invalid) { authorize(path: "/api/v1/models/999/download?license=personal") }
    assert_raises(Chat::PurchaseIntent::Invalid) { authorize(matched: @matched.merge(amount: "910000")) }
    assert_raises(Chat::PurchaseIntent::Invalid) do
      Chat::PurchaseIntent.authorize!(
        token: "tampered", offer: @offer, request_path: purchase_path,
        payload: payload("signed"), matched: @matched
      )
    end
    assert_equal "approved", @conversation.reload.purchase_proposal["state"]
  end

  private

  def authorize(transaction: "signed", path: purchase_path, matched: @matched)
    Chat::PurchaseIntent.authorize!(
      token: @token, offer: @offer, request_path: path,
      payload: payload(transaction), matched: matched
    )
  end

  def payload(transaction)
    { "payload" => { "transaction" => transaction } }
  end

  def purchase_path
    "/api/v1/models/#{@model.id}/download?license=personal"
  end

  def approved_proposal
    {
      "nonce" => "intent-nonce",
      "state" => "approved",
      "model_id" => @model.id,
      "title" => @model.title,
      "license_kind" => "personal",
      "price_cents" => 90,
      "purchase_path" => purchase_path,
      "expires_at" => 10.minutes.from_now.iso8601,
      "approved_asset" => X402::Requirements.usdc_asset,
      "approved_amount" => "900000"
    }
  end
end
