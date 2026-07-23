require "test_helper"

# V26 part 1: /about and /pricing follow the terms/privacy/takedown static-page
# pattern — unauthenticated, honest, testnet-labeled.
class PagesControllerTest < ActionDispatch::IntegrationTest
  test "about renders unauthenticated" do
    get about_path
    assert_response :success
    assert_match(/testnet/i, response.body)
  end

  test "pricing renders unauthenticated with the real economics" do
    get pricing_path
    assert_response :success
    assert_match "90%", response.body
    assert_match "10%", response.body
    assert_match(/settle(?:s)? to Printwright's\s+treasury/, response.body)
    assert_match "separate from buyer delivery", response.body
  end

  test "terms and API docs describe treasury settlement without obsolete direct-pay semantics" do
    get terms_path
    assert_response :success
    assert_match(/marketplace merchant of\s+record/, response.body)
    assert_match "remains owed in treasury", response.body
    assert_match(/does not revoke or delay the buyer's delivered\s+license/, response.body)

    get docs_path
    assert_response :success
    assert_match(/settle to Printwright's\s+treasury/, response.body)
    assert_match "offer_changed", response.body
  end

  test "privacy page accurately describes aggregate analytics boundaries" do
    get privacy_path

    assert_response :success
    assert_match(/daily impression, detail-view, and initial x402 quote-request\s+counters by model, surface, and human\/agent channel/, response.body)
    assert_match(/do not contain a buyer id.*session id.*query text.*user agent/m, response.body)
    assert_match(/No advertising, no tracking pixels, no sale of data/, response.body)
  end
end
