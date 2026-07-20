require "test_helper"

Capybara.default_max_wait_time = 5
Selenium::WebDriver.logger.level = :warn

# JS-capable base: headless Chrome for flows that run Stimulus (checkout).
class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 800 ] do |options|
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
  end

  # Loading webmock/minitest (any test file that stubs HTTP) disables net
  # connect process-wide with allow_localhost false, which also blocks
  # chromedriver on 127.0.0.1:9515. Whether a browser test survives then
  # depends on whether a test that re-allows localhost happened to run first —
  # order-dependent, so it passed locally and failed in CI on a different seed.
  # Every browser test needs its driver reachable; assert that up front.
  setup do
    if defined?(WebMock)
      WebMock.disable_net_connect!(allow_localhost: true)
      WebMock.stub_request(:get, %r{https://testnet\.mirrornode\.hedera\.com/api/v1/topics/.+/messages})
        .to_return(body: { messages: [] }.to_json)
    end
  end
end

# No-JS base: plain form flows (designer publish, verify page) don't need a
# browser — rack_test keeps them fast and dependency-free.
class RackSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :rack_test
end
