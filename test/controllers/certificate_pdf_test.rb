require "test_helper"

# The certificate as a keepable document. It is the same facts as the print
# page and the proof bundle, rendered server-side so an agent never has to
# drive a browser to hold its licence on paper.
class CertificatePdfTest < ActionDispatch::IntegrationTest
  setup do
    @license = licensed("Bracket Mount")
  end

  test "the PDF renders for a certificate that is anchored" do
    @license.update!(hcs_topic_id: "0.0.9585069", hcs_sequence_number: 42)

    get verify_certificate_pdf_path(@license.verify_slug)

    assert_response :success
    assert_equal "application/pdf", response.media_type
    assert response.body.start_with?("%PDF-"), "expected PDF magic bytes"
    assert_includes response.headers["Content-Disposition"], "printwright-certificate-#{@license.cert_id}.pdf"
  end

  test "the PDF renders before the anchor lands, because delivery precedes it" do
    assert_not_predicate @license, :anchored?

    get verify_certificate_pdf_path(@license.verify_slug)

    assert_response :success
    assert response.body.start_with?("%PDF-")
  end

  # An HCS anchor is asynchronous, but cert_json is written during delivery.
  # Between allocation and delivery it is the column default, {} — a licence
  # with nothing to attest to yet.
  test "a licence with no certificate yet has no PDF" do
    @license.update!(cert_json: {})

    get verify_certificate_pdf_path(@license.verify_slug)

    assert_response :not_found
  end

  test "an unknown slug does not render a certificate" do
    get verify_certificate_pdf_path("not-a-real-slug")

    assert_response :not_found
  end

  # Prawn's built-in fonts cover Windows-1252 only, and designers name their own
  # studios and models. Neither may take the certificate down.
  test "a title and studio name outside Windows-1252 still render" do
    designers(:one).update!(display_name: "スタジオ Ünicode ✦")
    license = licensed("Café Sign — Ø 40mm 日本語")

    get verify_certificate_pdf_path(license.verify_slug)

    assert_response :success
    assert response.body.start_with?("%PDF-")
  end

  test "the HTML certificate page is unchanged by the PDF rendering" do
    get verify_certificate_path(@license.verify_slug)

    assert_response :success
    assert_equal "text/html", response.media_type
    assert_select "button.print-btn", text: "Print / save as PDF"
  end

  private

  def licensed(title)
    model = Model3d.create!(designer: designers(:one), title: title,
      slug: "cert-pdf-#{SecureRandom.hex(4)}", status: "published",
      file_hash: "sha256:#{'a' * 64}")
    offer = model.license_offers.create!(kind: "personal", price_cents: 250, terms_md: "T.")
    purchase = Purchase.create!(license_offer: offer, status: "settled",
      replay_key: SecureRandom.hex(32), buyer_hint: "0.0.9067781",
      payment_tx_id: "0.0.7162784@#{SecureRandom.random_number(10**9)}.1")
    license = License.allocate!(purchase)
    purchase.transition_to!(:delivered)
    license.update!(cert_json: Certificates::Builder.call(license))
    license
  end
end
