require "test_helper"

class DesignerNavigationTest < ActionDispatch::IntegrationTest
  setup do
    @designer = designers(:two)
    @model = @designer.models3d.create!(title: "Navigation model",
      slug: "navigation-model-#{SecureRandom.hex(4)}")
    sign_in_as @designer
  end

  test "every seller destination names the current section in both navigation variants" do
    destinations = [
      [ designer_root_path, "Overview", designer_root_path ],
      [ designer_notifications_path, "Notifications", designer_notifications_path ],
      [ designer_models_path, "Models", designer_models_path ],
      [ edit_designer_model_path(@model), "Models", designer_models_path ],
      [ new_designer_model_path, "Add model", new_designer_model_path ],
      [ designer_imports_path, "Import catalog", designer_imports_path ],
      [ designer_identity_path, "Identity", designer_identity_path ],
      [ new_designer_takedown_packet_path, "Protection", new_designer_takedown_packet_path ],
      [ designer_sales_path, "Sales", designer_sales_path ],
      [ designer_payouts_path, "Payouts", designer_payouts_path ],
      [ designer_analytics_path, "Analytics", designer_analytics_path ],
      [ designer_webhook_endpoints_path, "Webhooks", designer_webhook_endpoints_path ],
      [ designer_account_path, "Account", designer_account_path ]
    ]

    destinations.each do |path, label, section_path|
      get path

      assert_response :success, path
      assert_select "details.dash-menu[open]", count: 0
      assert_select "details.dash-menu summary strong", text: label
      assert_select ".dash-nav-desktop a[aria-current='page'][href=?]", section_path, text: label
      assert_select ".dash-nav-mobile a[aria-current='page'][href=?]", section_path, text: label
      assert_select ".dash-nav-desktop a[aria-current='page']", count: 1
      assert_select ".dash-nav-mobile a[aria-current='page']", count: 1
    end
  end
end
