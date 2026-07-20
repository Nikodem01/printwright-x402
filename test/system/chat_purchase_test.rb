require "application_system_test_case"
require "webmock/minitest"
require_relative "support/test_wallet_controller"

class ChatPurchaseTest < ApplicationSystemTestCase
  FACILITATOR = "https://facilitator.test".freeze
  GEMINI = %r{\Ahttps://generativelanguage\.googleapis\.com/v1beta/models/gemini-3\.1-flash-lite:generateContent}
  ENV_NAMES = %w[
    GOOGLE_GENERATIVE_AI_API_KEY CHAT_PURCHASES_ENABLED CHAT_MAX_SPEND_CENTS CHAT_DAILY_SPEND_CENTS
    DEMO_WALLET_URL X402_FACILITATOR_URL X402_PAY_TO X402_DEMO_HBAR_PRICE_CENTS
  ].freeze

  setup do
    WebMock.disable_net_connect!(allow_localhost: true)
    @old_env = ENV_NAMES.index_with { |name| ENV[name] }
    ENV["GOOGLE_GENERATIVE_AI_API_KEY"] = "test-key"
    ENV["CHAT_PURCHASES_ENABLED"] = "true"
    ENV["CHAT_MAX_SPEND_CENTS"] = "100"
    ENV["CHAT_DAILY_SPEND_CENTS"] = "500"
    ENV["DEMO_WALLET_URL"] = "/__test_wallet__"
    ENV["X402_FACILITATOR_URL"] = FACILITATOR
    ENV["X402_PAY_TO"] = "0.0.9584959"
    ENV["X402_DEMO_HBAR_PRICE_CENTS"] = "250"
    FacilitatorClient.reset_cache!
    TestWalletController.reset!

    stub_request(:get, "#{FACILITATOR}/supported")
      .to_return(body: fixture("supported.json"), headers: { "content-type" => "application/json" })
    stub_request(:post, "#{FACILITATOR}/verify")
      .to_return(body: fixture("verify_ok.json"), headers: { "content-type" => "application/json" })
    stub_request(:post, "#{FACILITATOR}/settle")
      .to_return(body: fixture("settle_ok.json"), headers: { "content-type" => "application/json" })

    @model = Model3d.create!(
      designer: designers(:one), title: "Chat Approval Clip", slug: "chat-approval-clip",
      file_hash: "sha256:#{Digest::SHA256.hexdigest('chat clip')}", status: "published"
    )
    stl = @model.model_files.create!(kind: "stl", position: 0)
    stl.file.attach(io: StringIO.new("solid t\nendsolid t\n"), filename: "t.stl", content_type: "model/stl")
    @model.license_offers.create!(kind: "personal", price_cents: 25, currency: "HBAR", terms_md: "T.")

    stub_request(:post, GEMINI).to_return(
      { body: { candidates: [ { content: { parts: [
          { functionCall: { name: "propose_purchase", args: { id: @model.id.to_s, license_kind: "personal" }, id: "proposal-1" } }
        ] } } ] }.to_json, headers: { "content-type" => "application/json" } },
      { body: { candidates: [ { content: { parts: [ { text: "Review the approval card below." } ] } } ] }.to_json,
        headers: { "content-type" => "application/json" } }
    )
    stub_request(:get, "http://localhost:3000/api/v1/models/#{@model.id}").to_return(
      body: { id: @model.id, title: @model.title,
              license_offers: [ { kind: "personal", price_cents: 25, currency: "HBAR" } ] }.to_json,
      headers: { "content-type" => "application/json" }
    )
  end

  teardown do
    FacilitatorClient.reset_cache!
    TestWalletController.reset!
    @old_env.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  test "proposal requires one human click then uses the existing wallet and receipt path" do
    visit root_path
    page.execute_script("localStorage.setItem('printwright-theme', 'light')")
    refresh
    click_button "Help me buy with AI"

    assert_selector ".chat-msg-user"
    assert_equal "rgb(251, 252, 251)",
      page.evaluate_script("getComputedStyle(document.querySelector('.chat-msg-user p')).color")
    assert_selector ".chat-purchase-card", text: "Chat Approval Clip"
    assert_button "Approve and buy · 0.25 USDC"
    assert_equal 0, Purchase.count
    assert_equal 0, TestWalletController.sign_calls

    click_button "Approve and buy · 0.25 USDC"

    assert_selector ".badge-ok", text: "licensed"
    assert_text "Licensed — unit #1"
    assert_link "Download files"
    assert_equal 1, TestWalletController.sign_calls
    assert_equal "delivered", Purchase.sole.status
    assert_equal "completed", ChatConversation.order(:created_at).last.purchase_proposal["state"]
  ensure
    page.execute_script("localStorage.removeItem('printwright-theme')") if page.current_url.present?
  end

  test "a settlement timeout retries the identical signed payment without a second wallet prompt" do
    stub_request(:post, "#{FACILITATOR}/settle").to_timeout.then.to_return(
      body: fixture("settle_ok.json"), headers: { "content-type" => "application/json" }
    )
    stub_request(:get, %r{testnet\.mirrornode\.hedera\.com/api/v1/transactions})
      .to_return(body: '{"transactions":[]}', headers: { "content-type" => "application/json" })

    visit chat_path
    find("input[name=message]").fill_in with: "Buy the personal license for Chat Approval Clip."
    click_button "Send"
    click_button "Approve and buy · 0.25 USDC"

    assert_text "temporarily unavailable"
    assert_button "Try again"
    assert_equal 1, TestWalletController.sign_calls

    click_button "Try again"

    assert_selector ".badge-ok", text: "licensed"
    assert_equal 1, TestWalletController.sign_calls
    assert_equal 1, Purchase.count
  end

  test "reset chat returns the homepage shopkeeper to a fresh conversation" do
    visit root_path
    click_button "Help me buy with AI"
    assert_selector ".chat-msg-user"
    assert_button "Reset chat"

    click_button "Reset chat"

    assert_selector "#chat_empty_state", text: "Describe what you need"
    assert_no_selector ".chat-msg"
    assert_button "Reset chat"
  end

  private

  def fixture(name)
    file_fixture("x402/#{name}").read
  end
end
