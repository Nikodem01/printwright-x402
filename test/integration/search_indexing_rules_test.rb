require "test_helper"

# A receipt URL is a credential: whoever holds it can pull the paid file, with
# no account. If one is ever indexed, the file is public. So the rule is
# asserted from both ends — the paths that must carry `noindex` on every
# response shape, and the storefront that must stay findable.
class SearchIndexingRulesTest < ActionDispatch::IntegrationTest
  NOINDEX = "noindex, nofollow".freeze

  test "capability paths open to the public are noindex" do
    { "/library" => new_license_library_path, "/cart" => cart_path }.each do |label, path|
      get path

      assert_equal NOINDEX, response.headers["X-Robots-Tag"],
        "#{label} must be noindex whatever it responds with (was #{response.status})"
    end
  end

  test "authenticated areas are noindex once they actually render something" do
    sign_in_as designers(:one)

    { "/admin" => admin_root_path, "/designer" => designer_root_path }.each do |label, path|
      get path

      assert_response :success
      assert_equal NOINDEX, response.headers["X-Robots-Tag"], "#{label} must be noindex"
    end
  end

  # The one measured gap: Rodauth redirects out of the Rails response, so this
  # 302 loses the header. It is empty and points at a robots-disallowed path, so
  # there is nothing to index — pinned here so the reasoning is visible if the
  # behaviour ever changes.
  test "an unauthenticated bounce is an empty redirect to a disallowed path" do
    get admin_root_path

    assert_response :redirect
    assert_predicate response.body.strip, :empty?
    assert_match %r{/login}, response.headers["Location"]
  end

  # The one that matters most: a real receipt is a paid file behind a URL that
  # is itself the credential. Both the page and the download redirect must say
  # noindex, because either one leaking into an index leaks the file.
  test "a real receipt and its download are noindex" do
    license = delivered_license
    token = license.signed_id(purpose: "purchase-receipt")

    get purchase_receipt_path(license.cert_id), params: { token: token }
    assert_response :success
    assert_equal NOINDEX, response.headers["X-Robots-Tag"]

    get purchase_receipt_download_path(license.cert_id), params: { token: token }
    assert_response :redirect
    assert_equal NOINDEX, response.headers["X-Robots-Tag"],
      "the download redirect leads straight to the file bytes"
  end

  def delivered_license
    model = Model3d.create!(
      designer: designers(:one), title: "Indexing Clip",
      slug: "indexing-clip-#{SecureRandom.hex(4)}", file_hash: "sha256:#{'a' * 64}",
      status: "published"
    )
    file = model.model_files.create!(kind: "stl")
    file.file.attach(io: StringIO.new("solid i\nendsolid i\n"), filename: "i.stl",
                     content_type: "model/stl")
    offer = model.license_offers.create!(kind: "personal", price_cents: 250)
    purchase = Purchase.create!(
      license_offer: offer, status: "delivered", replay_key: SecureRandom.hex(32),
      buyer_hint: "0.0.9067781", payment_tx_id: "0.0.7162784@111.222"
    )
    License.allocate!(purchase).tap do |license|
      license.update!(cert_json: Certificates::Builder.call(license))
    end
  end

  test "the storefront and the catalog stay indexable" do
    get root_path

    assert_response :success
    assert_nil response.headers["X-Robots-Tag"]
    assert_select "meta[name=robots]", count: 0
  end

  test "certificate verification stays public proof, not hidden" do
    get verify_path(cert_id: "pw-000001")

    assert_nil response.headers["X-Robots-Tag"],
      "verification pages are meant to be linkable by anyone holding a cert id"
  end

  test "robots.txt disallows the capability links and leaves the catalog alone" do
    body = Rails.root.join("public/robots.txt").read
    disallowed = body.scan(/^Disallow:\s*(\S+)/).flatten

    %w[/receipts/ /library /cart /admin /designer/ /api/].each do |path|
      assert_includes disallowed, path
    end
    assert_not_includes disallowed, "/"
    assert_not_includes disallowed, "/verify/"
  end
end
