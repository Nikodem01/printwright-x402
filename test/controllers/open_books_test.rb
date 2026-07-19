require "test_helper"
require "webmock/minitest"

class OpenBooksTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    topic = "0.0.9585069"
    certificate = Base64.strict_encode64({ v: 1, cert_id: "pw-000050" }.to_json)
    stub_request(:get, "https://testnet.mirrornode.hedera.com/api/v1/topics/#{topic}/messages?limit=1&order=desc")
      .to_return(body: {
        messages: [ { topic_id: topic, sequence_number: 50,
                      consensus_timestamp: "1784449779.736670002", message: certificate } ]
      }.to_json)
  end

  teardown { Rails.cache.clear }

  test "public stats endpoint returns mirror and split facts without authentication" do
    get api_v1_stats_path

    assert_response :success
    assert_equal "hedera:testnet", response.parsed_body["network"]
    assert_equal 50, response.parsed_body.dig("hcs", "message_count")
    assert_equal 9000, response.parsed_body.dig("split", "designer_bps")
    assert_equal 1000, response.parsed_body.dig("split", "platform_bps")
    assert response.parsed_body.dig("ledger", "assets").is_a?(Array)
  end

  test "open-books page explains the sources and is linked from the footer" do
    get open_books_path

    assert_response :success
    assert_match "Open books", response.body
    assert_match "PWC-1 messages on HCS", response.body
    assert_match "90.0%", response.body
    assert_match "Raw latest-message query", response.body
    assert_match api_v1_stats_path, response.body

    get root_path
    assert_response :success
    assert_select "footer a[href=?]", open_books_path, text: "Open books"
  end
end
