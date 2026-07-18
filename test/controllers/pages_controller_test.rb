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
  end
end
