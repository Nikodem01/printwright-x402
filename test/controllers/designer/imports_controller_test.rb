require "test_helper"
require_relative "../../test_helpers/catalog_import_test_helper"

class Designer::ImportsControllerTest < ActionDispatch::IntegrationTest
  include CatalogImportTestHelper

  setup do
    post session_path, params: { email_address: designers(:one).email_address, password: "password" }
  end

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

  private

  def uploaded_archive(bytes)
    tempfile = Tempfile.new([ "catalog", ".zip" ])
    tempfile.binmode
    tempfile.write(bytes)
    tempfile.rewind
    Rack::Test::UploadedFile.new(tempfile.path, "application/zip", original_filename: "catalog.zip")
  end
end
