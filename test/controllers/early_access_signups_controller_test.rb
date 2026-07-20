require "test_helper"

class EarlyAccessSignupsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  test "landing form captures one normalized address and confirms it once" do
    assert_emails 1 do
      perform_enqueued_jobs(only: ActionMailer::MailDeliveryJob) do
        post designer_early_access_path, params: { email_address: " Designer@Example.com " }
      end
    end

    assert_redirected_to root_path
    assert_equal "designer@example.com", EarlyAccessSignup.sole.email_address
    assert_equal [ "designer@example.com" ], ActionMailer::Base.deliveries.last.to

    assert_no_emails do
      post designer_early_access_path, params: { email_address: "DESIGNER@example.com" }
    end
    assert_equal 1, EarlyAccessSignup.count
  end

  test "invalid address returns a visible validation message" do
    assert_no_difference -> { EarlyAccessSignup.count } do
      post designer_early_access_path, params: { email_address: "not-an-email" }
    end
    assert_redirected_to root_path
    follow_redirect!
    assert_select ".flash-bad", text: /Email address is invalid/
  end

  test "landing page explains the narrow consent boundary" do
    get root_path
    assert_response :success
    assert_select "form[action=?]", designer_early_access_path
    assert_select "section", text: /no account, newsletter, or public profile/i
  end
end
