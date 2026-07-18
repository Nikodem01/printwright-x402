require "test_helper"

Capybara.default_max_wait_time = 5

# JS-capable base: headless Chrome for flows that run Stimulus (checkout).
class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 800 ] do |options|
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
  end
end

# No-JS base: plain form flows (designer publish, verify page) don't need a
# browser — rack_test keeps them fast and dependency-free.
class RackSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :rack_test
end
