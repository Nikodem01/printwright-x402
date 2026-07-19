require "test_helper"
require "webmock/minitest"
require_relative "../../test_helpers/catalog_import_test_helper"

class CatalogImports::ProfileImporterTest < ActiveJob::TestCase
  include CatalogImportTestHelper

  FEED_URL = "https://profiles.example/printwright-profile.json".freeze
  PUBLIC_IP = "93.184.216.34".freeze

  setup do
    @previous_resolver = CatalogImports::RemoteFetcher.resolver
    CatalogImports::RemoteFetcher.resolver = ->(_host) { [ PUBLIC_IP ] }
    @stl = Rails.root.join("db/seed_assets/calibration-cube.stl").binread
  end

  teardown { CatalogImports::RemoteFetcher.resolver = @previous_resolver }

  test "preview allows proprietary originals and blocks Creative Commons with a reason" do
    stub_profile

    preview = CatalogImports::ProfileImporter.preview(FEED_URL)

    assert_equal "External Maker", preview.profile_name
    assert_match(/\Asha256:[0-9a-f]{64}\z/, preview.digest)
    original, remix = preview.models
    assert original.compatible
    assert_equal "eligible after your ownership warranty", original.reason
    assert_not remix.compatible
    assert_includes remix.reason, "Creative Commons terms remain attached"
    assert_not_requested :get, "https://files.example/cube.stl"
  end

  test "selected warranted original imports as a rollbackable draft with provenance" do
    stub_profile
    stub_request(:get, "https://files.example/cube.stl").to_return(status: 200, body: @stl)
    preview = CatalogImports::ProfileImporter.preview(FEED_URL)

    catalog_import = CatalogImports::ProfileImporter.call(
      designers(:one), feed_url: FEED_URL, expected_digest: preview.digest,
      external_ids: [ "maker-cube" ]
    )

    model = catalog_import.models3d.sole
    assert_predicate model, :draft?
    assert_equal "https://profiles.example/models/cube", model.source_url
    assert_equal "all-rights-reserved", model.source_license
    assert model.ownership_warranted_at
    assert model.printable_files.one?
    assert model.license_offers.one?
    assert_equal "external_profile", catalog_import.source_kind
    assert_equal "https://profiles.example/maker", catalog_import.source_url
    assert_equal [ "maker-cube" ], catalog_import.provenance.fetch("external_model_ids")
    assert_equal "v1", catalog_import.provenance.fetch("ownership_warranty_version")
    assert_equal CatalogImports::Snapshot.digest(model), catalog_import.model_snapshots.fetch(model.id.to_s)
    assert_equal 1, CatalogImports::Rollback.call(catalog_import)
  end

  test "blocked license cannot be selected and downloads nothing" do
    stub_profile
    preview = CatalogImports::ProfileImporter.preview(FEED_URL)

    error = assert_raises(CatalogImports::Error) do
      CatalogImports::ProfileImporter.call(
        designers(:one), feed_url: FEED_URL, expected_digest: preview.digest,
        external_ids: [ "maker-remix" ]
      )
    end

    assert_includes error.message, "Creative Commons terms remain attached"
    assert_not_requested :get, %r{\Ahttps://files\.example/}
    assert_equal 0, CatalogImport.count
  end

  test "changed profile and mismatched file hashes leave no drafts" do
    original = external_profile_json
    changed = JSON.generate(external_profile_document.merge(profile: { name: "Changed", url: "https://profiles.example/maker" }))
    stub_request(:get, FEED_URL).to_return(
      { status: 200, body: original, headers: { "content-type" => "application/json" } },
      { status: 200, body: changed, headers: { "content-type" => "application/json" } }
    )
    preview = CatalogImports::ProfileImporter.preview(FEED_URL)

    error = assert_raises(CatalogImports::Error) do
      CatalogImports::ProfileImporter.call(
        designers(:one), feed_url: FEED_URL, expected_digest: preview.digest,
        external_ids: [ "maker-cube" ]
      )
    end
    assert_includes error.message, "changed after review"
    assert_equal 0, Model3d.where(slug: "external-maker-cube").count

    stub_profile
    stub_request(:get, "https://files.example/cube.stl").to_return(status: 200, body: "solid wrong\nendsolid wrong\n")
    preview = CatalogImports::ProfileImporter.preview(FEED_URL)
    error = assert_raises(CatalogImports::Error) do
      CatalogImports::ProfileImporter.call(
        designers(:one), feed_url: FEED_URL, expected_digest: preview.digest,
        external_ids: [ "maker-cube" ]
      )
    end
    assert_includes error.message, "hash does not match"
    assert_equal 0, Model3d.where(slug: "external-maker-cube").count
  end

  test "remote fetcher rejects private DNS before opening a connection" do
    CatalogImports::RemoteFetcher.resolver = ->(_host) { [ "127.0.0.1" ] }

    error = assert_raises(CatalogImports::Error) do
      CatalogImports::ProfileImporter.preview(FEED_URL)
    end

    assert_includes error.message, "non-public address"
    assert_not_requested :get, FEED_URL
  end

  private

  def stub_profile
    stub_request(:get, FEED_URL).to_return(
      status: 200, body: external_profile_json, headers: { "content-type" => "application/json" }
    )
  end
end
