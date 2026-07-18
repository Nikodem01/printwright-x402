require "application_system_test_case"
require "webmock/minitest"

# The human door, driven end to end in a real browser: the checkout Stimulus
# state machine (quote 402 -> wallet sign -> settle -> receipt) against the
# same captured-wire facilitator stubs the API tests use. The signer is the
# in-app test wallet (test/system/support/test_wallet_controller.rb).
class CheckoutTest < ApplicationSystemTestCase
  FACILITATOR = "https://facilitator.test".freeze

  # Saved/restored around each test so a value in the developer's shell survives.
  X402_ENV = %w[X402_FACILITATOR_URL X402_PAY_TO X402_DEMO_HBAR_PRICE_CENTS DEMO_WALLET_URL TEST_WALLET_MODE].freeze

  setup do
    WebMock.disable_net_connect!(allow_localhost: true)
    @env_was = X402_ENV.index_with { |k| ENV[k] }
    ENV["DEMO_WALLET_URL"] = "/__test_wallet__"
    ENV["X402_FACILITATOR_URL"] = FACILITATOR
    ENV["X402_PAY_TO"] = "0.0.9584959"
    ENV["X402_DEMO_HBAR_PRICE_CENTS"] = "250" # 25c offer => exactly 0.1 HBAR, matching the fixture
    FacilitatorClient.reset_cache!
    stub_request(:get, "#{FACILITATOR}/supported")
      .to_return(body: fixture("supported.json"), headers: { "content-type" => "application/json" })

    @model = Model3d.create!(
      designer: designers(:one), title: "Browser Buy", slug: "browser-buy",
      file_hash: "sha256:#{Digest::SHA256.hexdigest('spike')}", status: "published"
    )
    stl = @model.model_files.create!(kind: "stl", position: 0)
    stl.file.attach(io: StringIO.new("solid t\nendsolid t\n"), filename: "t.stl", content_type: "model/stl")
    @model.license_offers.create!(kind: "personal", price_cents: 25, currency: "HBAR", terms_md: "T.")
  end

  teardown do
    FacilitatorClient.reset_cache!
    @env_was.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  test "buying in the browser walks the x402 states and lands on a receipt" do
    stub_request(:post, "#{FACILITATOR}/verify")
      .to_return(body: fixture("verify_ok.json"), headers: { "content-type" => "application/json" })
    stub_request(:post, "#{FACILITATOR}/settle")
      .to_return(body: fixture("settle_ok.json"), headers: { "content-type" => "application/json" })

    settled_tx = JSON.parse(fixture("settle_ok.json"))["transaction"]

    visit model_page_path(@model.slug)
    click_button "Buy license · $0.25"

    assert_selector ".badge-ok", text: "licensed"
    assert_text "Licensed — unit #1"
    assert_selector "a", text: settled_tx
    assert_selector "a", text: /\Apw-\d{6,}\z/
    assert_link "Download files"
    assert_no_button "Buy license · $0.25"

    purchase = Purchase.last
    assert_equal "delivered", purchase.status
    assert_equal @model, purchase.license_offer.model3d
    assert_equal settled_tx, purchase.payment_tx_id
  end

  test "facilitator rejection surfaces the failed state with a retry button" do
    stub_request(:post, "#{FACILITATOR}/verify")
      .to_return(body: fixture("verify_invalid.json"), headers: { "content-type" => "application/json" })

    visit model_page_path(@model.slug)
    click_button "Buy license · $0.25"

    assert_selector ".badge-bad", text: "failed"
    assert_text "invalid_signature"
    assert_button "Try again"
    assert_equal "failed_verification", Purchase.last.status
  end

  test "wallet refusal fails without ever creating a purchase" do
    ENV["TEST_WALLET_MODE"] = "refuse"

    visit model_page_path(@model.slug)
    assert_no_changes -> { Purchase.count } do
      click_button "Buy license · $0.25"
      assert_selector ".badge-bad", text: "failed"
      assert_text "wallet refused: signing refused"
    end
  end

  private

  def fixture(name)
    file_fixture("x402/#{name}").read
  end
end
