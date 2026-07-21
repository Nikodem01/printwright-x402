require "test_helper"

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
    offer = @model.license_offers.create!(kind: "personal", price_cents: 250)
    purchase = Purchase.create!(
      license_offer: offer, status: "delivered", replay_key: SecureRandom.hex(32),
      buyer_hint: "0.0.9067781", payment_tx_id: "0.0.7162784@111.222"
    )
    @license = License.allocate!(purchase)
    @license.update!(cert_json: Certificates::Builder.call(@license))
    @token = @license.signed_id(purpose: "purchase-receipt")
  end

  test "paid receipt capability renders no-store facts and reissues a download grant" do
    get purchase_receipt_path(@license.cert_id), params: { token: @token }

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select 'meta[name="robots"][content="noindex,nofollow"]'
    assert_select "h1", text: "Purchase receipt"
    assert_select "a", text: "Re-download model file"
    assert_select "form[action=?]", receipt_library_membership_path(@license.cert_id)

    assert_difference -> { DownloadGrant.count }, 1 do
      get purchase_receipt_download_path(@license.cert_id), params: { token: @token }
    end
    assert_redirected_to api_v1_file_path(DownloadGrant.order(:id).last.token)
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
