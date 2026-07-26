require "test_helper"

# config/environments/test.rb turns forgery protection off for the whole suite,
# so no ordinary test can see a CSRF regression — that is how a total publish
# outage (F1) shipped behind a fully green CI. Flipping it globally is not the
# answer: sign_in_as and much of the suite depend on it being off. Instead this
# turns it on for one leg at a time, covering the non-GET flows a browser can
# reach that do NOT get a Rails-minted per-form token:
#
#   * JS fetch() calls that carry the meta-tag token by hand
#     (checkout_controller.js: cart completion DELETE, chat approval POST)
#   * the csrf-token meta tag itself, which every one of those depends on
#
# The retargeting publish form is covered by publish_csrf_test.rb, and the
# OmniAuth request phase by oauth_csrf_test.rb.
#
# Each flow is asserted twice: accepted with the token, and REJECTED without
# it. The second half is what keeps these tests honest — an "accepted" assertion
# alone still passes when protection is quietly off, which is the exact blind
# spot this file exists to close.
class BrowserCsrfTest < ActionDispatch::IntegrationTest
  setup do
    @forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @forgery_protection
  end

  # Every fetch()-driven flow reads this one tag; if it ever stops rendering,
  # all of them break at once and only in a real browser.
  def meta_token
    get root_path
    assert_response :success
    token = css_select("meta[name='csrf-token']").first&.[]("content")
    assert token.present?, "the layout must render csrf_meta_tags for fetch() flows to work"
    token
  end

  test "the cart completion DELETE the checkout controller fires is accepted with the meta token" do
    delete cart_path, headers: { "X-CSRF-Token" => meta_token }

    assert_response :no_content
  end

  test "the cart completion DELETE is rejected without a token" do
    meta_token # establish the same session, then omit the header

    delete cart_path

    assert_forgery_rejected
  end

  test "the chat approval POST is accepted with the meta token" do
    post approve_chat_purchase_path, headers: { "X-CSRF-Token" => meta_token }

    # Purchases are disabled by default, so the action answers its own domain
    # error. What matters here is that it reached the action at all rather than
    # being turned away as a forgery.
    assert_not_equal 422, response.status
    assert_equal "purchases_disabled", response.parsed_body["error"]
  end

  test "the chat approval POST is rejected without a token" do
    meta_token

    post approve_chat_purchase_path

    assert_forgery_rejected
  end

  # Adding to the cart is a normal form POST, but it is browser-only and
  # non-GET, so it belongs to the same untested class.
  test "adding to the cart requires a valid token and works with one" do
    model = Model3d.create!(designer: designers(:one), title: "Csrf Cart", slug: "csrf-cart",
      status: "published", file_hash: "sha256:#{'e' * 64}")
    model.license_offers.create!(kind: "personal", price_cents: 25, terms_md: "T.")
    params = { model_id: model.id, license: "personal" }

    post cart_items_path, params: params, headers: { "X-CSRF-Token" => meta_token }
    assert_response :redirect

    post cart_items_path, params: params
    assert_forgery_rejected
  end

  private

  # show_exceptions is :rescuable in test, so an InvalidAuthenticityToken is
  # rendered as a 422 rather than propagating — the same 422 a browser saw when
  # publishing was broken.
  def assert_forgery_rejected
    assert_response :unprocessable_entity,
      "forgery protection did not reject a token-less non-GET request"
  end
end
