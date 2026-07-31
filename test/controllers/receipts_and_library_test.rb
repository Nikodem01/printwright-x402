require "test_helper"
require "zip"

class ReceiptsAndLibraryTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  setup do
    @model = Model3d.create!(
      designer: designers(:one), title: "Library Clip", slug: "library-clip-#{SecureRandom.hex(4)}",
      file_hash: "sha256:#{'a' * 64}", status: "published"
    )
    file = @model.model_files.create!(kind: "stl")
    file.file.attach(
      io: StringIO.new("solid library\nendsolid library\n"),
      filename: "library.stl", content_type: "model/stl"
    )
    @offer = @model.license_offers.create!(kind: "personal", price_cents: 250)
    purchase = Purchase.create!(
      license_offer: @offer, status: "delivered", replay_key: SecureRandom.hex(32),
      buyer_hint: "0.0.9067781", payment_tx_id: "0.0.7162784@111.222"
    )
    @license = License.allocate!(purchase)
    @license.update!(cert_json: Certificates::Builder.call(@license))
    @token = @license.signed_id(purpose: "purchase-receipt")
  end

  test "receipt, certificate, and download keep the purchased offer after a future revision" do
    original_hash = @license.cert_json.fetch("terms_hash")
    current = LicenseOffers::Reviser.call(model: @model,
      attributes: { id: @offer.id, kind: "commercial_unit", price_cents: 500 })
    @model.update!(status: "retired")

    get purchase_receipt_path(@license.cert_id), params: { token: @token }
    assert_response :success
    assert_select "dd", text: /Personal/
    assert_equal @offer, @license.purchase.reload.license_offer
    assert_equal original_hash, @license.reload.cert_json.fetch("terms_hash")
    assert_equal "commercial_unit", current.kind

    assert_difference -> { DownloadGrant.count }, 1 do
      get purchase_receipt_download_path(@license.cert_id), params: { token: @token }
    end
    grant = DownloadGrant.order(:id).last
    assert_redirected_to api_v1_file_path(grant.token, f: 0)
    get api_v1_file_path(grant.token, f: 0)
    assert_response :redirect

    get verify_path(@license.verify_slug)
    assert_response :success
    assert_select ".cert-eyebrow", text: "License certificate"

    updates_token = @license.signed_id(purpose: "model-updates")
    get api_v1_license_latest_version_path(@license.cert_id),
      headers: { "Authorization" => "Bearer #{updates_token}" }
    assert_response :success
    assert_equal @model.file_hash, response.parsed_body["file_hash"]
    get api_v1_license_latest_version_file_path(@license.cert_id),
      headers: { "Authorization" => "Bearer #{updates_token}" }
    assert_response :redirect
  end

  test "paid receipt capability renders no-store facts and re-mints a download grant on demand" do
    get purchase_receipt_path(@license.cert_id), params: { token: @token }

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select 'meta[name="robots"][content="noindex,nofollow"]'
    assert_select "h1", text: "Purchase receipt"
    assert_select "a", text: "Download model + certificate (.zip)"
    assert_select "a", text: "Re-download STL"
    assert_select "form[action=?]", receipt_library_membership_path(@license.cert_id)

    assert_difference -> { DownloadGrant.count }, 1 do
      get purchase_receipt_download_path(@license.cert_id), params: { token: @token }
    end
    first_grant = DownloadGrant.order(:id).last
    assert_redirected_to api_v1_file_path(first_grant.token, f: 0)

    # A second visit rides the grant that is already live rather than piling up
    # tokens; once that one lapses, the receipt mints a fresh one. This is what
    # makes the receipt — not the purchase response — the durable path.
    assert_no_difference -> { DownloadGrant.count } do
      get purchase_receipt_download_path(@license.cert_id), params: { token: @token }
    end
    assert_redirected_to api_v1_file_path(first_grant.token, f: 0)

    travel DownloadGrant::LIFETIME + 1.day do
      assert_difference -> { DownloadGrant.count }, 1 do
        get purchase_receipt_download_path(@license.cert_id), params: { token: @token }
      end
      fresh = DownloadGrant.order(:id).last
      assert_not_equal first_grant.token, fresh.token
      get api_v1_file_path(fresh.token, f: 0)
      assert_response :redirect
    end
  end

  test "complete package contains every model file and the certificate PDF" do
    get purchase_receipt_package_path(@license.cert_id), params: { token: @token }

    assert_response :success
    assert_equal "application/zip", response.media_type
    Zip::File.open_buffer(response.body) do |zip|
      assert_equal [ "01-library.stl", "printwright-certificate-#{@license.cert_id}.pdf", "proof-bundle.json" ],
        zip.entries.map(&:name)
      assert_equal "solid library\nendsolid library\n", zip.read("01-library.stl")
      assert zip.read("printwright-certificate-#{@license.cert_id}.pdf").start_with?("%PDF")
      # The exact machine-readable preimage: every hash in the PDF appendix is
      # recomputable offline from this file plus the model bytes above.
      bundle = JSON.parse(zip.read("proof-bundle.json"))
      assert_equal Certificates::Bundle.for(@license.reload), bundle
    end
  end

  # The receipt page is a browser affordance; the same URL and token have to
  # answer an agent too, or the durable path is humans-only.
  test "the receipt answers JSON with live download URLs for every part" do
    get purchase_receipt_path(@license.cert_id, format: :json), params: { token: @token }

    assert_response :success
    body = response.parsed_body
    assert_equal @license.cert_id, body["cert_id"]
    assert_equal @model.title, body.dig("model", "title")
    assert_equal 1, body["files"].length
    assert_equal "stl", body["files"].first["kind"]

    get body["files"].first["url"]
    assert_response :redirect
    follow_redirect! while response.redirect? # grant -> blob redirect -> disk service
    assert_equal "solid library\nendsolid library\n", response.body
  end

  test "receipt rejects a wrong capability and every sandbox license" do
    get purchase_receipt_path(@license.cert_id), params: { token: "wrong" }
    assert_response :not_found

    sandbox_purchase = Purchase.create!(
      license_offer: @license.purchase.license_offer, status: "delivered",
      replay_key: SecureRandom.hex(32), sandbox: true
    )
    sandbox = License.allocate!(sandbox_purchase)
    get purchase_receipt_path(sandbox.cert_id),
      params: { token: sandbox.signed_id(purpose: "purchase-receipt") }
    assert_response :not_found
  end

  test "optional email sends a magic link that opens every saved license without keeping the token URL" do
    assert_emails 1 do
      perform_enqueued_jobs(only: ActionMailer::MailDeliveryJob) do
        post receipt_library_membership_path(@license.cert_id),
          params: { token: @token, email_address: " Buyer@Example.com " }
      end
    end

    membership = LibraryMembership.sole
    assert_equal "buyer@example.com", membership.email_address
    assert_redirected_to purchase_receipt_path(@license.cert_id, token: @token)
    mail = ActionMailer::Base.deliveries.last
    assert_equal [ "buyer@example.com" ], mail.to
    assert_includes mail.text_part.body.to_s, "/library/access?token="

    magic_token = LibraryMembership.access_token("buyer@example.com")
    get access_license_library_path, params: { token: magic_token }
    assert_redirected_to license_library_path
    follow_redirect!
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select "h1", text: "Your license library"
    assert_select "h2", text: @model.title
    assert_select "a", text: "Re-download"
    assert_no_match magic_token, response.body
  end

  test "returning sign-in never enumerates membership and expired links fail" do
    @license.create_library_membership!(email_address: "buyer@example.com")

    assert_no_emails do
      post new_license_library_path, params: { email_address: "unknown@example.com" }
    end
    assert_redirected_to new_license_library_path

    assert_emails 1 do
      perform_enqueued_jobs(only: ActionMailer::MailDeliveryJob) do
        post new_license_library_path, params: { email_address: "BUYER@example.com" }
      end
    end
    assert_redirected_to new_license_library_path

    token = LibraryMembership.access_token("buyer@example.com")
    travel 31.minutes do
      get access_license_library_path, params: { token: token }
      assert_redirected_to new_license_library_path
      assert_equal "That library link is invalid or expired.", flash[:alert]
    end
  end

  test "signing out everywhere revokes an already-issued library cookie (S7)" do
    @license.create_library_membership!(email_address: "buyer@example.com")
    token = LibraryMembership.access_token("buyer@example.com")

    # A second device holds a valid library cookie.
    device_b = open_session
    device_b.get access_license_library_path, params: { token: token }
    device_b.get license_library_path
    assert_equal 200, device_b.response.status

    # This device signs out of the library everywhere.
    get access_license_library_path, params: { token: token }
    delete revoke_license_library_path
    assert_redirected_to new_license_library_path

    # The second device's cookie is now void.
    device_b.get license_library_path
    assert_equal 302, device_b.response.status
    assert_match %r{/library/sign-in}, device_b.response.location
  end
end
