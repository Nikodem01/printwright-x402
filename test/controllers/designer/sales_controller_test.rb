require "test_helper"
require "csv"

class Designer::SalesControllerTest < ActionDispatch::IntegrationTest
  setup do
    ENV["X402_PAY_TO"] = "0.0.9584959"
    @designer = designers(:one)
    @designer.update!(hedera_account_id: "0.0.9604186")
    model = Model3d.create!(designer: @designer, title: "Ledger Lamp", slug: "lamp-#{SecureRandom.hex(4)}")
    @offer = model.license_offers.create!(kind: "personal", price_cents: 250)
    sign_in_as @designer
  end

  def settled_purchase(pay_to:, amount: "250000", offer: @offer, buyer_hint: "0.0.9067781")
    purchase = Purchase.create!(
      license_offer: offer, status: "verified", buyer_hint: buyer_hint,
      asset: "0.0.429274", amount_base_units: amount,
      payment_tx_id: "0.0.7162784@#{SecureRandom.rand(1000)}.#{SecureRandom.rand(1000)}",
      replay_key: SecureRandom.hex(32), requirements_json: { "payTo" => pay_to }
    )
    purchase.transition_to!(:settled)
    purchase
  end

  test "Sales shows period totals, full UTC dates, all ledger states, and expandable proof" do
    direct = settled_purchase(pay_to: "0.0.9604186")
    owed = settled_purchase(pay_to: "0.0.9584959")
    paid = settled_purchase(pay_to: "0.0.9584959")
    LedgerEntry.create!(purchase: paid, designer: @designer, entry_kind: "designer_payout",
      asset: "0.0.429274", amount_base_units: "225000", held_by: "designer", tx_id: "0.0.9067781@9.9")
    refunded = settled_purchase(pay_to: "0.0.9584959")
    LedgerEntry.create!(purchase: refunded, entry_kind: "refund",
      asset: "0.0.429274", amount_base_units: "250000", held_by: "treasury", tx_id: "0.0.9067781@8.8")
    License.allocate!(direct)

    get designer_sales_path

    assert_response :success
    assert_select "h1", text: "Sales"
    assert_select ".business-tabs a[aria-current='page']", text: "Sales"
    assert_select ".home-metric", text: /Delivered sales.*4/m
    assert_select ".home-metric", text: /Gross sales.*1\.00 USDC/m
    assert_select ".home-metric", text: /Printwright fee \(10%\).*0\.10 USDC/m
    assert_select ".home-metric", text: /Your share \(90%\).*0\.90 USDC/m
    assert_select "td", text: "Paid at settlement (legacy)", count: 1
    assert_select "td", text: "Payout held", count: 1
    assert_select "td", text: "Payout paid", count: 1
    assert_select "td", text: "Refunded to buyer", count: 1
    assert_select "time", text: /\A\d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC\z/, count: 4
    assert_select "details.sale-proof", count: 4
    assert_select "details.sale-proof", text: /Buyer payment.*Designer payout/m, count: 1
    assert_select "details.sale-proof", text: /Buyer payment.*Buyer refund/m, count: 1
    assert_select "details.sale-proof", text: /Certificate.*#{direct.license.cert_id}/m, count: 1
    assert_match "Buyer delivery, receipts, certificates, downloads, and license", response.body
    assert_equal [ owed.id ], LedgerEntry.owed.where(designer: @designer).pluck(:purchase_id)
  end

  test "Sales filters controlled periods without changing historical ledger rows" do
    old_model = @designer.models3d.create!(title: "Archive Vase", slug: "archive-vase-#{SecureRandom.hex(4)}")
    old_offer = old_model.license_offers.create!(kind: "personal", price_cents: 500)
    travel_to 45.days.ago do
      settled_purchase(pay_to: "0.0.9584959", amount: "500000", offer: old_offer)
    end
    settled_purchase(pay_to: "0.0.9584959")

    get designer_sales_path(period: "30d")
    assert_select "tbody tr", count: 1
    assert_no_match "Archive Vase", response.body

    get designer_sales_path(period: "90d")
    assert_select "tbody tr", count: 2
    assert_match "Archive Vase", response.body

    get designer_sales_path(period: "unsupported")
    assert_select ".money-periods a[aria-current='page']", text: "Last 30 days"
    assert_select "tbody tr", count: 1
    assert_equal 2, LedgerEntry.where(designer: @designer, entry_kind: "designer_share").count
  end

  test "custom UTC dates are inclusive and drive the same HTML and CSV rows" do
    today = Time.current.utc.to_date
    start_date = today - 50.days
    end_date = today - 40.days
    start_offer = offer_for("Start boundary")
    end_offer = offer_for("End boundary")
    outside_offer = offer_for("Outside boundary")
    travel_to Time.utc(start_date.year, start_date.month, start_date.day) do
      settled_purchase(pay_to: "0.0.9584959", offer: start_offer)
    end
    travel_to Time.utc(end_date.year, end_date.month, end_date.day, 23, 59, 59) do
      settled_purchase(pay_to: "0.0.9584959", offer: end_offer)
    end
    travel_to Time.utc((end_date + 1.day).year, (end_date + 1.day).month, (end_date + 1.day).day) do
      settled_purchase(pay_to: "0.0.9584959", offer: outside_offer)
    end
    filter = { start_date: start_date.iso8601, end_date: end_date.iso8601 }

    get designer_sales_path(filter)

    assert_response :success
    assert_select "p", text: /Custom statement.*#{start_date} through #{end_date}.*inclusive, UTC/m
    assert_select "tbody tr", count: 2
    assert_match "Start boundary", response.body
    assert_match "End boundary", response.body
    assert_no_match "Outside boundary", response.body
    assert_select "a[href=?]", export_designer_sales_path(filter), text: "Export custom range CSV"

    get export_designer_sales_path(filter)

    assert_response :success
    csv = CSV.parse(response.body, headers: true)
    assert_equal [ "End boundary", "Start boundary" ], csv.map { |row| row["model"] }
    assert_match(/printwright-sales-#{start_date}-to-#{end_date}-\d{4}-\d{2}-\d{2}\.csv/,
      response.headers["Content-Disposition"])
  end

  test "invalid custom dates never silently produce a differently bounded statement or export" do
    settled_purchase(pay_to: "0.0.9584959")
    today = Time.current.utc.to_date
    invalid_filters = [
      [ { start_date: today.iso8601, end_date: "" }, /both a start date and an end date/ ],
      [ { start_date: "not-a-date", end_date: today.iso8601 }, /valid dates in YYYY-MM-DD/ ],
      [ { start_date: today.iso8601, end_date: (today - 1.day).iso8601 }, /on or after the start date/ ],
      [ { start_date: (today - 366.days).iso8601, end_date: today.iso8601 }, /at most 366 days/ ],
      [ { start_date: today.iso8601, end_date: (today + 1.day).iso8601 }, /cannot be in the future/ ]
    ]

    invalid_filters.each do |filter, message|
      get designer_sales_path(filter)
      assert_response :unprocessable_entity
      assert_select "[role='alert']", text: message
      assert_select "[role='alert']", text: /Showing the default last 30 days/
      assert_select "tbody tr", count: 1
    end

    get export_designer_sales_path(start_date: today.iso8601, end_date: "")
    assert_redirected_to designer_sales_path(start_date: today.iso8601, end_date: "")
    assert_not_equal "text/csv", response.media_type
  end

  test "Sales calls an unpaid balance pending only when the payout destination is verified" do
    @designer.update!(payout_account_verified_at: Time.current)
    settled_purchase(pay_to: "0.0.9584959")

    get designer_sales_path

    assert_response :success
    assert_select "td", text: "Payout pending", count: 1
  end

  test "Sales CSV is scoped, formula-safe, and excludes buyer and capability secrets" do
    private_hint = "buyer-private@example.com"
    dangerous_model = @designer.models3d.create!(title: "=HYPERLINK(\"bad\")",
      slug: "formula-#{SecureRandom.hex(4)}")
    dangerous_offer = dangerous_model.license_offers.create!(kind: "personal", price_cents: 250)
    purchase = settled_purchase(pay_to: "0.0.9584959", offer: dangerous_offer, buyer_hint: private_hint)
    other_purchase_for(designers(:two), title: "Other studio secret")

    get export_designer_sales_path(period: "all")

    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_match(/attachment; filename="printwright-sales-all-\d{4}-\d{2}-\d{2}\.csv"/, response.headers["Content-Disposition"])
    csv = CSV.parse(response.body, headers: true)
    assert_equal %w[sale_at_utc model license gross_base_units platform_fee_base_units
      designer_share_base_units asset payout_status payment_transaction payout_transaction
      refund_transaction certificate_id], csv.headers
    assert_equal 1, csv.size
    assert_equal "'=HYPERLINK(\"bad\")", csv.first["model"]
    assert_equal purchase.payment_tx_id, csv.first["payment_transaction"]
    assert_no_match private_hint, response.body
    assert_no_match purchase.replay_key, response.body
    assert_no_match "Other studio secret", response.body
  end

  test "Sales CSV neutralizes every spreadsheet formula prefix" do
    controller = Designer::SalesController.new
    [ "+SUM(1,1)", "-1+1", "@cmd", "\tpayload", "\rpayload", "\npayload" ].each do |title|
      assert_equal "'#{title}", controller.send(:csv_text, title)
    end
    assert_equal "Ordinary title", controller.send(:csv_text, "Ordinary title")
  end

  test "legacy payout anchor forwards to Payouts without duplicating wallet controls" do
    get designer_sales_path(anchor: "payout-destination")

    assert_response :success
    assert_select "#payout-destination", text: /Payout settings have moved.*Payouts/m
    assert_select "#payout-destination a[href=?]", designer_payouts_path(anchor: "payout-destination")
    assert_select "form[action=?]", designer_payout_destination_path, count: 0
  end

  test "Payouts separates destination controls, balances, timing, and grouped transfer history" do
    @designer.update!(payout_account_verified_at: Time.current,
      payout_account_control_verified_at: Time.current)
    paid_one = settled_purchase(pay_to: "0.0.9584959")
    paid_two = settled_purchase(pay_to: "0.0.9584959", amount: "100000")
    settled_purchase(pay_to: "0.0.9584959", amount: "500000")
    [ [ paid_one, 225_000 ], [ paid_two, 90_000 ] ].each do |purchase, amount|
      LedgerEntry.create!(purchase: purchase, designer: @designer, entry_kind: "designer_payout",
        asset: "0.0.429274", amount_base_units: amount, held_by: "designer", tx_id: "0.0.9067781@7.7")
    end

    get designer_payouts_path

    assert_response :success
    assert_select "h1", text: "Payouts"
    assert_select ".business-tabs a[aria-current='page']", text: "Payouts"
    assert_select ".home-metric", text: /Awaiting payout.*0\.45 USDC.*Eligible for automatic payout/m
    assert_select ".home-metric", text: /Paid out.*0\.32 USDC/m
    assert_select "#payout-destination", text: /Active.*0\.0\.9604186.*Verified/m
    assert_select "form[action=?]", designer_payout_destination_path
    assert_select ".payout-table tbody tr", count: 1
    assert_select ".payout-table tbody tr", text: /2 sales.*0\.32 USDC.*Recorded on-chain.*0\.0\.9067781/m
    assert_match "exact arrival time is not promised", response.body
    assert_match "current wallet may have changed", response.body
  end

  test "Payouts shows awaiting proof and replacement safety hold recovery states" do
    @designer.update!(payout_pending_account_id: "0.0.7007",
      payout_challenge: "signed challenge", payout_challenge_digest: "digest",
      payout_challenge_expires_at: 10.minutes.from_now,
      payout_change_requested_at: Time.current)

    get designer_payouts_path
    assert_select "#payout-destination", text: /Awaiting proof.*0\.0\.7007.*single-use challenge/m
    assert_select "form[action=?]", verify_designer_payout_destination_path

    @designer.update!(payout_account_verified_at: Time.current,
      payout_account_control_verified_at: Time.current,
      payout_proof_verified_at: Time.current, payout_hold_until: 24.hours.from_now)
    get designer_payouts_path
    assert_select "#payout-destination", text: /Safety hold.*0\.0\.9604186.*0\.0\.7007.*current destination remains active/m
    assert_select "form[action=?]", activate_designer_payout_destination_path, count: 0
    assert_select "form[action=?]", designer_payout_destination_path
  end

  test "Sales, exports, and Payouts require authentication and stay tenant-scoped" do
    other_purchase_for(designers(:two), title: "Other designer model", payout: true)

    [ designer_sales_path(period: "all"), designer_payouts_path ].each do |path|
      get path
      assert_response :success
      assert_no_match "Other designer model", response.body
      assert_no_match "0.0.5555@1.1", response.body
    end

    get export_designer_sales_path(period: "all")
    assert_no_match "Other designer model", response.body

    sign_out
    [ designer_sales_path, designer_payouts_path, export_designer_sales_path ].each do |path|
      get path
      assert_redirected_to "/login"
    end
  end

  private

  def offer_for(title)
    model = @designer.models3d.create!(title: title, slug: "#{title.parameterize}-#{SecureRandom.hex(4)}")
    model.license_offers.create!(kind: "personal", price_cents: 250)
  end

  def other_purchase_for(designer, title:, payout: false)
    model = designer.models3d.create!(title: title, slug: "other-#{SecureRandom.hex(4)}")
    offer = model.license_offers.create!(kind: "personal", price_cents: 100)
    purchase = Purchase.create!(license_offer: offer, status: "verified", asset: "0.0.429274",
      amount_base_units: "100000", payment_tx_id: "0.0.5555@#{SecureRandom.rand(1000)}.1",
      replay_key: SecureRandom.hex(32), requirements_json: { "payTo" => "0.0.9584959" })
    purchase.transition_to!(:settled)
    if payout
      LedgerEntry.create!(purchase: purchase, designer: designer, entry_kind: "designer_payout",
        asset: "0.0.429274", amount_base_units: 90_000, held_by: "designer", tx_id: "0.0.5555@1.1")
    end
    purchase
  end
end
