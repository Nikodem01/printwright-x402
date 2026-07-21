require "test_helper"
require "webmock/minitest"
require_relative "../../test_helpers/catalog_import_test_helper"

class Designer::ImportsControllerTest < ActionDispatch::IntegrationTest
  include CatalogImportTestHelper

  setup do
    sign_in_as designers(:one)
    @previous_resolver = CatalogImports::RemoteFetcher.resolver
    CatalogImports::RemoteFetcher.resolver = ->(_host) { [ "93.184.216.34" ] }
  end

  teardown { CatalogImports::RemoteFetcher.resolver = @previous_resolver }

  test "uploads an archive and rolls its unchanged drafts back" do
    upload = uploaded_archive(catalog_archive.bytes)

    post designer_imports_path, params: { archive: upload }

    catalog_import = designers(:one).catalog_imports.last
    assert_redirected_to designer_imports_path
    assert_equal 2, catalog_import.model_count
    assert_equal 2, catalog_import.models3d.count

    delete designer_import_path(catalog_import)
    assert_redirected_to designer_imports_path
    assert_predicate catalog_import.reload, :rolled_back?
    assert_empty catalog_import.models3d
  ensure
    upload&.tempfile&.close!
  end

  test "does not expose another designer's import" do
    catalog_import = designers(:two).catalog_imports.create!(manifest_digest: "sha256:test")

    delete designer_import_path(catalog_import)

    assert_response :not_found
  end

  test "reviews source licenses then imports only a separately warranted original" do
    feed_url = "https://profiles.example/printwright-profile.json"
    profile_json = external_profile_json
    stl = Rails.root.join("db/seed_assets/calibration-cube.stl").binread
    stub_request(:get, feed_url).to_return(status: 200, body: profile_json)
    stub_request(:get, "https://files.example/cube.stl").to_return(status: 200, body: stl)

    post preview_designer_imports_path, params: { feed_url: feed_url }

    assert_response :success
    assert_select "h2", text: "Review External Maker"
    assert_select "span.badge-bad", text: "blocked"
    assert_match "Creative Commons terms remain attached", response.body
    digest = "sha256:#{Digest::SHA256.hexdigest(profile_json)}"

    post designer_imports_path, params: {
      profile_url: feed_url, profile_digest: digest, external_ids: [ "maker-cube" ]
    }

    assert_redirected_to designer_imports_path
    catalog_import = designers(:one).catalog_imports.order(:id).last
    assert_equal "external_profile", catalog_import.source_kind
    assert_equal "https://profiles.example/models/cube", catalog_import.models3d.sole.source_url
    follow_redirect!
    assert_select "a", text: "External Maker"
  end

  private

  def uploaded_archive(bytes)
    tempfile = Tempfile.new([ "catalog", ".zip" ])
    tempfile.binmode
    tempfile.write(bytes)
    tempfile.rewind
    Rack::Test::UploadedFile.new(tempfile.path, "application/zip", original_filename: "catalog.zip")
  end
end
