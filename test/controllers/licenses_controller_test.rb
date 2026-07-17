require "test_helper"

class LicensesControllerTest < ActionDispatch::IntegrationTest
  test "txt permalink serves the exact canonical bytes (the hash recipe input)" do
    get license_document_path(version: "v1", kind: "personal", format: :txt)
    assert_response :success
    assert_equal Licensing::Documents.text("v1", "personal"), response.body
    assert_equal "sha256:#{Digest::SHA256.hexdigest(response.body)}",
                 Licensing::Documents.hash("v1", "personal")
  end

  test "html page shows the text, the hash, and the recipe" do
    get license_document_path(version: "v1", kind: "commercial_unit")
    assert_response :success
    assert_match Licensing::Documents.hash("v1", "commercial_unit"), response.body
    assert_match "sha256sum", response.body
    assert_match "Commercial Per-Unit", response.body
  end

  test "unknown versions and kinds 404" do
    get "/license/v9/personal"
    assert_response :not_found
    get "/license/v1/site_wide"
    assert_response :not_found
  end
end
