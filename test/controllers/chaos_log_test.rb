require "test_helper"

class ChaosLogTest < ActionDispatch::IntegrationTest
  test "publishes only completed adversarial runs" do
    get chaos_log_path

    assert_response :success
    assert_select "h1", text: "Chaos log"
    assert_select "[data-chaos-run]", 2
    assert_match "2,000", response.body
    assert_match "64 random grant-token guesses", response.body

    get root_path
    assert_select "footer a[href=?]", chaos_log_path, text: "Chaos log"
  end
end
