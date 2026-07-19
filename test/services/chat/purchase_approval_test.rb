require "test_helper"
require "webmock/minitest"

class Chat::PurchaseApprovalTest < ActiveSupport::TestCase
  BASE_URL = "http://www.example.com"
  PURCHASE_PATH = "/api/v1/models/5/download?license=personal"

  setup do
    @old_env = ENV.values_at("CHAT_PURCHASES_ENABLED", "CHAT_MAX_SPEND_CENTS", "CHAT_DAILY_SPEND_CENTS")
    ENV["CHAT_PURCHASES_ENABLED"] = "true"
    ENV["CHAT_MAX_SPEND_CENTS"] = "500"
    ENV["CHAT_DAILY_SPEND_CENTS"] = "1000"
    @conversation = ChatConversation.create!(purchase_proposal: proposal)
  end

  teardown do
    %w[CHAT_PURCHASES_ENABLED CHAT_MAX_SPEND_CENTS CHAT_DAILY_SPEND_CENTS].zip(@old_env).each do |name, value|
      value.nil? ? ENV.delete(name) : ENV[name] = value
    end
  end

  test "approval reserves budget and returns an exact-USDC quote plus signed route intent" do
    stub_quote

    result = Chat::PurchaseApproval.call(conversation: @conversation, base_url: BASE_URL)

    assert_equal "#{BASE_URL}#{PURCHASE_PATH}", result.purchase_url
    assert_equal [ X402::Requirements.usdc_asset ], result.payment_required["accepts"].pluck("asset")
    assert result.purchase_intent.present?

    stored = @conversation.reload.purchase_proposal
    assert_equal "approved", stored["state"]
    assert_equal "900000", stored["approved_amount"]
    assert_equal 90, @conversation.approved_spend_cents
    refute_match(/payment_required|payment-signature|download_grant|files/, JSON.generate(stored))
  end

  test "repeating approval before submission does not reserve the budget twice" do
    stub_quote

    2.times { Chat::PurchaseApproval.call(conversation: @conversation, base_url: BASE_URL) }

    assert_equal 90, @conversation.reload.approved_spend_cents
  end

  test "disabled, expired, stale-price, and over-cap proposals fail before signing" do
    ENV["CHAT_PURCHASES_ENABLED"] = "false"
    error = assert_raises(Chat::PurchaseApproval::Failure) do
      Chat::PurchaseApproval.call(conversation: @conversation, base_url: BASE_URL)
    end
    assert_equal "purchases_disabled", error.code
    assert_not_requested :get, "#{BASE_URL}#{PURCHASE_PATH}"

    ENV["CHAT_PURCHASES_ENABLED"] = "true"
    @conversation.update!(purchase_proposal: proposal.merge("expires_at" => 1.minute.ago.iso8601))
    error = assert_raises(Chat::PurchaseApproval::Failure) do
      Chat::PurchaseApproval.call(conversation: @conversation, base_url: BASE_URL)
    end
    assert_equal "approval_expired", error.code

    @conversation.update!(purchase_proposal: proposal)
    stub_quote(amount: "910000")
    error = assert_raises(Chat::PurchaseApproval::Failure) do
      Chat::PurchaseApproval.call(conversation: @conversation, base_url: BASE_URL)
    end
    assert_equal "stale_proposal", error.code

    @conversation.update!(purchase_proposal: proposal.merge("price_cents" => 501))
    stub_quote(amount: "5010000")
    error = assert_raises(Chat::PurchaseApproval::Failure) do
      Chat::PurchaseApproval.call(conversation: @conversation, base_url: BASE_URL)
    end
    assert_equal "spend_cap_exceeded", error.code
  end

  test "conversation and daily cumulative caps reserve atomically" do
    @conversation.update!(approved_spend_cents: 450)
    stub_quote
    error = assert_raises(Chat::PurchaseApproval::Failure) do
      Chat::PurchaseApproval.call(conversation: @conversation, base_url: BASE_URL)
    end
    assert_equal "spend_cap_exceeded", error.code

    @conversation.update!(approved_spend_cents: 0)
    ChatConversation.create!(approved_spend_cents: 950)
    error = assert_raises(Chat::PurchaseApproval::Failure) do
      Chat::PurchaseApproval.call(conversation: @conversation, base_url: BASE_URL)
    end
    assert_equal "daily_spend_cap_exceeded", error.code
  end

  private

  def proposal
    {
      "nonce" => "proposal-nonce",
      "state" => "pending",
      "model_id" => 5,
      "title" => "Cable Clip",
      "license_kind" => "personal",
      "price_cents" => 90,
      "display_price" => "$0.90",
      "purchase_path" => PURCHASE_PATH,
      "expires_at" => 10.minutes.from_now.iso8601
    }
  end

  def stub_quote(amount: "900000")
    body = {
      x402Version: 2,
      error: "payment required",
      resource: { url: "#{BASE_URL}#{PURCHASE_PATH}", description: "license", mimeType: "application/json" },
      accepts: [
        { scheme: "exact", network: X402::Requirements.network, amount: "1000000", asset: "0.0.0",
          payTo: "0.0.123", maxTimeoutSeconds: 180, extra: { feePayer: "0.0.456" } },
        { scheme: "exact", network: X402::Requirements.network, amount: amount, asset: X402::Requirements.usdc_asset,
          payTo: "0.0.123", maxTimeoutSeconds: 180, extra: { feePayer: "0.0.456" } }
      ]
    }
    stub_request(:get, "#{BASE_URL}#{PURCHASE_PATH}").to_return(
      status: 402, body: body.to_json, headers: { "content-type" => "application/json" }
    )
  end
end

class Chat::PurchaseApprovalConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    ChatConversation.delete_all
    ENV["CHAT_PURCHASES_ENABLED"] = "true"
    ENV["CHAT_MAX_SPEND_CENTS"] = "100"
    ENV["CHAT_DAILY_SPEND_CENTS"] = "100"
  end

  teardown do
    ChatConversation.delete_all
    ENV.delete("CHAT_PURCHASES_ENABLED")
    ENV.delete("CHAT_MAX_SPEND_CENTS")
    ENV.delete("CHAT_DAILY_SPEND_CENTS")
  end

  test "concurrent approvals serialize the daily budget so only one can reserve" do
    path = "/api/v1/models/5/download?license=personal"
    body = {
      x402Version: 2,
      resource: { url: "http://www.example.com#{path}" },
      accepts: [ { scheme: "exact", network: X402::Requirements.network, amount: "600000",
                   asset: X402::Requirements.usdc_asset, payTo: "0.0.123", extra: { feePayer: "0.0.456" } } ]
    }
    stub_request(:get, "http://www.example.com#{path}").to_return(status: 402, body: body.to_json)

    ids = 2.times.map do |index|
      ChatConversation.create!(purchase_proposal: {
        "nonce" => "concurrent-#{index}", "state" => "pending", "model_id" => 5,
        "title" => "Clip", "license_kind" => "personal", "price_cents" => 60,
        "display_price" => "$0.60", "purchase_path" => path, "expires_at" => 10.minutes.from_now.iso8601
      }).id
    end
    ready = Queue.new
    start = Queue.new
    results = Queue.new
    threads = ids.map do |id|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          begin
            Chat::PurchaseApproval.call(conversation: ChatConversation.find(id), base_url: "http://www.example.com")
            results << "approved"
          rescue Chat::PurchaseApproval::Failure => e
            results << e.code
          end
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    threads.each(&:join)

    assert_equal [ "approved", "daily_spend_cap_exceeded" ], 2.times.map { results.pop }.sort
    assert_equal 60, ChatConversation.sum(:approved_spend_cents)
    assert_equal 1, ChatConversation.where("purchase_proposal ->> 'state' = 'approved'").count
  end
end
