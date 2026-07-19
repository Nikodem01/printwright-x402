require "test_helper"
require "webmock/minitest"

class ChaosLogTest < ActionDispatch::IntegrationTest
  setup do
    @old_topic = ENV["HEDERA_HEARTBEAT_TOPIC_ID"]
    ENV.delete("HEDERA_HEARTBEAT_TOPIC_ID")
    Rails.cache.clear
  end

  teardown do
    ENV["HEDERA_HEARTBEAT_TOPIC_ID"] = @old_topic
    Rails.cache.clear
  end

  test "publishes only completed adversarial runs and honest heartbeat state" do
    get chaos_log_path

    assert_response :success
    assert_select "h1", text: "Chaos log"
    assert_select "[data-chaos-run]", 2
    assert_match "2,000", response.body
    assert_match "64 random grant-token guesses", response.body
    assert_match "Not configured", response.body
    assert_match "does not prove every storefront or payment dependency is healthy", response.body

    get root_path
    assert_select "footer a[href=?]", chaos_log_path, text: "Chaos log"
  end
end
