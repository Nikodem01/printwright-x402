require "test_helper"

class ProductionChatTest < ActiveSupport::TestCase
  test "production deploy enables bounded testnet chat purchases" do
    deploy = Rails.root.join("config/deploy.yml").read

    assert_includes deploy, 'CHAT_PURCHASES_ENABLED: <%= ENV.fetch("CHAT_PURCHASES_ENABLED", "true") %>'
    assert_includes deploy, 'CHAT_MAX_SPEND_CENTS: <%= ENV.fetch("CHAT_MAX_SPEND_CENTS", "500") %>'
    assert_includes deploy, 'CHAT_DAILY_SPEND_CENTS: <%= ENV.fetch("CHAT_DAILY_SPEND_CENTS", "2500") %>'
  end
end
