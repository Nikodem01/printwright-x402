require "test_helper"

# V24: the human-readable API docs page — quickstart, error contract, MCP —
# must render for unauthenticated visitors (the audience is integrators, not
# logged-in designers).
class DocsPageTest < ActionDispatch::IntegrationTest
  test "renders unauthenticated with the key sections" do
    get docs_path
    assert_response :success
    assert_match "Quickstart", response.body
    assert_match "@printwright/client", response.body
    assert_match "printwright.search", response.body
    assert_match "printwright.get", response.body
    assert_match "Try the whole flow free", response.body
    assert_match "sandbox: true", response.body
    assert_match "PAYMENT-SIGNATURE", response.body
    assert_match "Error contract", response.body
    assert_match "duplicate_payment", response.body
    assert_match "Printability metadata", response.body
    assert_match "est_print_minutes", response.body
    assert_match "designer-declared slicing guidance", response.body
    assert_match "Load sanity", response.body
    assert_match "scripts/load-sanity.mjs", response.body
    assert_match "MCP", response.body
    assert_match "claude mcp add printwright", response.body
  end
end
