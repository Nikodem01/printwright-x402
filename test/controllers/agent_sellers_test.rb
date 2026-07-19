require "test_helper"

class AgentSellersTest < ActionDispatch::IntegrationTest
  test "directory is public, curated, and honest about verification" do
    get agent_sellers_path

    assert_response :success
    assert_select "h1", text: "Agent-buyable sellers"
    assert_select "[data-seller]", 3
    assert_select "[data-seller]", text: /Printwright/
    assert_select "[data-seller]", text: /Current Weather/
    assert_select "[data-seller]", text: /Weather Forecast & Air Quality/
    assert_match(/challenge verified/i, response.body)
    assert_match(/not an endorsement/i, response.body)
    assert_match(/2026-07-19/, response.body)
  end

  test "footer links to the directory" do
    get root_path
    assert_select "footer a[href=?]", agent_sellers_path, text: "Agent sellers"
  end
end
