require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "downcases and strips email_address" do
    designer = Designer.new(email_address: " DOWNCASED@EXAMPLE.COM ")
    assert_equal("downcased@example.com", designer.email_address)
  end
end
