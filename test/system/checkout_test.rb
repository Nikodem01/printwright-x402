require "application_system_test_case"
require "timeout"
require "webmock/minitest"
# Required here rather than relied on from another test file, so this one can
# be run on its own.
require_relative "support/test_wallet_controller"

# The human door, driven end to end in a real browser: the checkout Stimulus
# state machine (quote 402 -> wallet sign -> settle -> receipt) against the
# same captured-wire facilitator stubs the API tests use. The signer is the
# in-app test wallet (test/system/support/test_wallet_controller.rb).
class CheckoutTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  FACILITATOR = "https://facilitator.test".freeze

  setup do
    WebMock.disable_net_connect!(allow_localhost: true)
    set_printwright(demo_wallet_url: "/__test_wallet__")
    set_printwright(demo_hbar_price_cents: "250") # 25c offer => exactly 0.1 HBAR, matching the fixture
    FacilitatorClient.reset_cache!
    TestWalletController.reset!
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
    TestWalletController.reset!
  end

  test "buying in the browser walks the x402 states and lands on a receipt" do
    @model.license_offers.sole.update!(max_units: 25)
    stub_request(:post, "#{FACILITATOR}/verify")
      .to_return(body: fixture("verify_ok.json"), headers: { "content-type" => "application/json" })
    stub_request(:post, "#{FACILITATOR}/settle")
      .to_return(body: fixture("settle_ok.json"), headers: { "content-type" => "application/json" })

    settled_tx = JSON.parse(fixture("settle_ok.json"))["transaction"]

    visit model_page_path(@model.slug)
    click_button "Buy license · 0.25 USDC"

    assert_selector ".badge-ok", text: "licensed"
    assert_text "Personal license — unlimited personal prints"
    assert_text "24 of 25 license slots now remain"
    assert_selector "img[alt^='Share card for pw-']"
    assert_selector "a", text: settled_tx
    # Unguessable by design: a sequential id would let anyone walk the reveals.
    assert_selector "a", text: /\Apw-[0-9a-f]{16,}\z/
    assert_link "Download model + certificate (.zip)"
    assert_no_button "Buy license · 0.25 USDC"

    purchase = Purchase.last
    assert_equal "delivered", purchase.status
    assert_equal @model, purchase.license_offer.model3d
    assert_equal settled_tx, purchase.payment_tx_id

    click_link "Open durable receipt"
    assert_current_path purchase_receipt_path(purchase.license.cert_id), ignore_query: true
    assert_text "Purchase receipt"
    assert_link "Re-download STL"

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

    grant = DownloadGrant.uncached { DownloadGrant.order(:id).last }
    uses = grant.uses
    click_link "Re-download"
    Timeout.timeout(Capybara.default_max_wait_time) do
      sleep 0.05 until DownloadGrant.uncached { grant.reload.uses } > uses
    end

    # The buyer really pulled the file down again, and the grant already issued
    # at purchase was reused rather than piling up a token per click. The
    # durable thing is the receipt capability, not the grant.
    assert_equal 1, DownloadGrant.uncached { DownloadGrant.count }
  end

  test "facilitator rejection surfaces the failed state with a human message, retry button, and the raw reason" do
    stub_request(:post, "#{FACILITATOR}/verify")
      .to_return(body: fixture("verify_invalid.json"), headers: { "content-type" => "application/json" })

    visit model_page_path(@model.slug)
    click_button "Buy license · 0.25 USDC"

    assert_selector ".badge-bad", text: "failed"
    assert_text "The payment could not be completed."
    assert_text "invalid_signature"
    assert_button "Try again"
    assert_equal "failed_verification", Purchase.last.status
  end

  # A buyer whose account cannot cover the charge is the first person to hit
  # this, and the facilitator's own code is the whole of what they used to see.
  # It has to say what to do about it, and stay retryable — funding the account
  # is exactly the thing that makes a retry work.
  test "a preflight rejection tells the buyer to check their balance instead of showing a raw code" do
    stub_request(:post, "#{FACILITATOR}/verify")
      .to_return(body: fixture("verify_preflight_failed.json"),
        headers: { "content-type" => "application/json" })

    visit model_page_path(@model.slug)
    click_button "Buy license · 0.25 USDC"

    assert_selector ".badge-bad", text: "failed"
    assert_text "Your wallet could not make this transfer"
    assert_text "Check the balance, then try again."
    # The operator-facing detail stays visible, just no longer as the whole message.
    assert_text "invalid_exact_hedera_payload_preflight_failed"
    assert_button "Try again"
  end

  test "wallet refusal explains the decline in plain language, keeps the raw reason, and invites a retry" do
    ENV["TEST_WALLET_MODE"] = "refuse"

    visit model_page_path(@model.slug)
    assert_no_changes -> { Purchase.count } do
      click_button "Buy license · 0.25 USDC"
      assert_selector ".badge-bad", text: "failed"
      assert_text "You declined the payment request in your wallet."
      assert_text "wallet refused: signing refused"
      assert_button "Try again"
    end
  end

  # With no signer configured at all, the buyer never saw a wallet prompt, so
  # "you declined the payment request in your wallet" accused them of an action
  # they could not have taken — and it appeared alongside the true reason, which
  # contradicted it. Only the configuration statement is true here.
  test "an unconfigured wallet says so instead of blaming the buyer for declining" do
    # and no walletconnect_project_id, so no loader is attached either
    set_printwright(demo_wallet_url: nil)

    visit model_page_path(@model.slug)
    assert_no_changes -> { Purchase.count } do
      click_button "Buy license · 0.25 USDC"
      assert_selector ".badge-bad", text: "failed"
      assert_text "This deployment has no browser wallet configured"
      assert_no_text "You declined the payment request in your wallet."
      # Retrying cannot configure a wallet, so the button must not invite it.
      assert_no_button "Try again"
      assert_button "No wallet configured", disabled: true
    end
  end

  test "a sold-out offer fails immediately with a non-retryable message, before any wallet prompt" do
    @model.license_offers.sole.update!(max_units: 0)

    visit model_page_path(@model.slug)
    assert_no_changes -> { Purchase.count } do
      click_button "Buy license · 0.25 USDC"
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
    click_button "Buy license · 0.25 USDC"
    assert_selector "button[disabled]", text: "Sold out"

    find("input[type=radio][value=commercial_unit]").click

    assert_no_selector "button[disabled]"
    assert_button "Buy 1 commercial unit · 0.50 USDC"
    assert_no_selector ".badge-bad"
  end

  test "commercial quantity settles once and delivers one license per unit" do
    @model.license_offers.create!(
      kind: "commercial_unit", price_cents: 60, currency: "USDC", terms_md: "T.", max_units: 5
    )
    stub_request(:post, "#{FACILITATOR}/verify")
      .to_return(body: fixture("verify_ok.json"), headers: { "content-type" => "application/json" })
    stub_request(:post, "#{FACILITATOR}/settle")
      .to_return(body: fixture("settle_ok.json"), headers: { "content-type" => "application/json" })

    visit model_page_path(@model.slug)
    find("input[type=radio][value=commercial_unit]").click
    fill_in "Units", with: 3

    assert_button "Buy 3 commercial units · 1.80 USDC"
    click_button "Buy 3 commercial units · 1.80 USDC"

    assert_selector ".badge-ok", text: "licensed"
    assert_text "3 commercial units licensed"
    assert_selector ".batch-license", count: 3
    assert_selector ".batch-download", count: 3
    assert_equal 3, Purchase.where(license_offer: @model.license_offers.find_by!(kind: "commercial_unit")).count
    assert_equal [ "delivered" ], Purchase.distinct.pluck(:status)
    assert_equal 1, PurchaseBatch.count
    assert_requested :post, "#{FACILITATOR}/settle", times: 1
  end

  test "cart combines different models and settles them with one wallet approval" do
    second = Model3d.create!(
      designer: designers(:one), title: "Batch Companion", slug: "batch-companion",
      file_hash: "sha256:#{Digest::SHA256.hexdigest('batch companion')}", status: "published"
    )
    file = second.model_files.create!(kind: "stl", position: 0)
    file.file.attach(io: StringIO.new("solid b\nendsolid b\n"), filename: "b.stl", content_type: "model/stl")
    second.license_offers.create!(kind: "commercial_unit", price_cents: 60, currency: "USDC", max_units: 5)
    stub_request(:post, "#{FACILITATOR}/verify")
      .to_return(body: fixture("verify_ok.json"), headers: { "content-type" => "application/json" })
    stub_request(:post, "#{FACILITATOR}/settle")
      .to_return(body: fixture("settle_ok.json"), headers: { "content-type" => "application/json" })

    visit model_page_path(@model.slug)
    click_button "Add selection to cart"
    assert_link "Cart (1)"

    visit model_page_path(second.slug)
    fill_in "Units", with: 2
    click_button "Add selection to cart"
    click_link "Cart (3)"

    page.driver.browser.manage.window.resize_to(360, 900)
    overflow = page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")
    assert_operator overflow, :<=, 1, "filled cart overflows horizontally at 360px"
    assert_text "Your cart"
    assert_text "Browser Buy"
    assert_text "Batch Companion"
    assert_text "1.45 USDC"
    click_button "Approve cart · 1.45 USDC"

    assert_selector ".badge-ok", text: "licensed"
    assert_text "3 licenses purchased"
    assert_selector ".batch-license", count: 3
    assert_equal 3, Purchase.count
    assert_equal 1, PurchaseBatch.count
    assert_equal 1, TestWalletController.sign_calls
    assert_requested :post, "#{FACILITATOR}/settle", times: 1

    visit root_path
    assert_link "Cart"
    assert_no_link "Cart (3)"
  end

  test "a one-item cart uses a singular license heading" do
    stub_request(:post, "#{FACILITATOR}/verify")
      .to_return(body: fixture("verify_ok.json"), headers: { "content-type" => "application/json" })
    stub_request(:post, "#{FACILITATOR}/settle")
      .to_return(body: fixture("settle_ok.json"), headers: { "content-type" => "application/json" })

    visit model_page_path(@model.slug)
    click_button "Add selection to cart"
    click_link "Cart (1)"
    click_button "Approve cart · 0.25 USDC"

    assert_text "1 license purchased"
    assert_no_text "1 licenses purchased"
  end

  test "retrying a rejected payment surfaces duplicate_payment as a terminal, non-retryable state" do
    stub_request(:post, "#{FACILITATOR}/verify")
      .to_return(body: fixture("verify_invalid.json"), headers: { "content-type" => "application/json" })

    visit model_page_path(@model.slug)
    click_button "Buy license · 0.25 USDC"
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
