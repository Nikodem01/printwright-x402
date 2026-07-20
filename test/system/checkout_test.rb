require "application_system_test_case"
require "timeout"
require "webmock/minitest"

# The human door, driven end to end in a real browser: the checkout Stimulus
# state machine (quote 402 -> wallet sign -> settle -> receipt) against the
# same captured-wire facilitator stubs the API tests use. The signer is the
# in-app test wallet (test/system/support/test_wallet_controller.rb).
class CheckoutTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

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
    ActionMailer::Base.deliveries.clear
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
    @model.license_offers.sole.update!(max_units: 25)
    stub_request(:post, "#{FACILITATOR}/verify")
      .to_return(body: fixture("verify_ok.json"), headers: { "content-type" => "application/json" })
    stub_request(:post, "#{FACILITATOR}/settle")
      .to_return(body: fixture("settle_ok.json"), headers: { "content-type" => "application/json" })

    settled_tx = JSON.parse(fixture("settle_ok.json"))["transaction"]

    visit model_page_path(@model.slug)
    click_button "Buy license · 0.10 ℏ · $0.25"

    assert_selector ".badge-ok", text: "licensed"
    assert_text "Licensed — unit #1 of 25"
    assert_text "24 of 25 license slots now remain"
    assert_selector "img[alt^='Share card for pw-']"
    assert_selector "a", text: settled_tx
    assert_selector "a", text: /\Apw-\d{6,}\z/
    assert_link "Download files"
    assert_no_button "Buy license · 0.10 ℏ · $0.25"

    purchase = Purchase.last
    assert_equal "delivered", purchase.status
    assert_equal @model, purchase.license_offer.model3d
    assert_equal settled_tx, purchase.payment_tx_id

    click_link "Open durable receipt"
    assert_current_path purchase_receipt_path(purchase.license.cert_id), ignore_query: true
    assert_text "Purchase receipt"
    assert_link "Re-download model file"

    fill_in "Email address", with: "browser-buyer@example.com"
    perform_enqueued_jobs(only: ActionMailer::MailDeliveryJob) do
      click_button "Email my private library link"
      assert_text "Check your email for a private library link."
    end
    access_url = URI.extract(ActionMailer::Base.deliveries.last.text_part.body.to_s, %w[http https]).first
    visit URI(access_url).request_uri
    assert_current_path license_library_path
    assert_text "Your license library"
    assert_text "Browser Buy"

    grant_count = DownloadGrant.uncached { DownloadGrant.count }
    click_link "Re-download"
    Timeout.timeout(Capybara.default_max_wait_time) do
      sleep 0.05 until DownloadGrant.uncached { DownloadGrant.count } == grant_count + 1
    end
    assert_equal grant_count + 1, DownloadGrant.uncached { DownloadGrant.count }
  end

  test "facilitator rejection surfaces the failed state with a human message, retry button, and the raw reason" do
    stub_request(:post, "#{FACILITATOR}/verify")
      .to_return(body: fixture("verify_invalid.json"), headers: { "content-type" => "application/json" })

    visit model_page_path(@model.slug)
    click_button "Buy license · 0.10 ℏ · $0.25"

    assert_selector ".badge-bad", text: "failed"
    assert_text "The payment could not be completed."
    assert_text "invalid_signature"
    assert_button "Try again"
    assert_equal "failed_verification", Purchase.last.status
  end

  test "wallet refusal explains the decline in plain language, keeps the raw reason, and invites a retry" do
    ENV["TEST_WALLET_MODE"] = "refuse"

    visit model_page_path(@model.slug)
    assert_no_changes -> { Purchase.count } do
      click_button "Buy license · 0.10 ℏ · $0.25"
      assert_selector ".badge-bad", text: "failed"
      assert_text "You declined the payment request in your wallet."
      assert_text "wallet refused: signing refused"
      assert_button "Try again"
    end
  end

  test "a sold-out offer fails immediately with a non-retryable message, before any wallet prompt" do
    @model.license_offers.sole.update!(max_units: 0)

    visit model_page_path(@model.slug)
    assert_no_changes -> { Purchase.count } do
      click_button "Buy license · 0.10 ℏ · $0.25"
      assert_selector ".badge-bad", text: "failed"
      assert_text "This offer is sold out — there are no license slots left."
      assert_selector "button[disabled]", text: "Sold out"
      assert_no_button "Try again"
    end
  end

  # A terminal failure belongs to the offer that produced it, not to the model.
  # Regression: disabling the button on terminal states left it stuck disabled
  # when the buyer then picked a different, still-buyable offer.
  test "switching to another offer clears a terminal failure and re-enables buying" do
    @model.license_offers.sole.update!(max_units: 0)
    @model.license_offers.create!(kind: "commercial_unit", price_cents: 50, currency: "HBAR", terms_md: "T.")

    visit model_page_path(@model.slug)
    click_button "Buy license · 0.10 ℏ · $0.25"
    assert_selector "button[disabled]", text: "Sold out"

    find("input[type=radio][value=commercial_unit]").click

    assert_no_selector "button[disabled]"
    assert_button "Buy license · 0.20 ℏ · $0.50"
    assert_no_selector ".badge-bad"
  end

  test "retrying a rejected payment surfaces duplicate_payment as a terminal, non-retryable state" do
    stub_request(:post, "#{FACILITATOR}/verify")
      .to_return(body: fixture("verify_invalid.json"), headers: { "content-type" => "application/json" })

    visit model_page_path(@model.slug)
    click_button "Buy license · 0.10 ℏ · $0.25"
    assert_selector ".badge-bad", text: "failed"
    assert_button "Try again"

    click_button "Try again"

    assert_selector ".badge-bad", text: "failed"
    assert_text "This payment was already submitted and is being handled — retrying here won't help."
    assert_text "duplicate_payment"
    assert_selector "button[disabled]", text: "Already submitted"
    assert_no_button "Try again"
    assert_equal 1, Purchase.count
  end

  private

  def fixture(name)
    file_fixture("x402/#{name}").read
  end
end
