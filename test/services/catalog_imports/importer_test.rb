require "test_helper"
require_relative "../../test_helpers/catalog_import_test_helper"

class CatalogImports::ImporterTest < ActiveJob::TestCase
  include CatalogImportTestHelper

  test "imports fifty publishable drafts with files renders and offers under five minutes" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    catalog_import = CatalogImports::Importer.call(designers(:one), catalog_archive(count: 50))

    models = catalog_import.models3d.includes(:license_offers, model_files: { file_attachment: :blob })
    models.each { |model| AnalyzeModelMeshJob.perform_now(model.id) }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, 300
    assert_equal 50, models.length
    assert models.all?(&:draft?)
    assert models.all? { |model| model.printable_files.one? && model.render_files.one? }
    assert models.all? { |model| model.license_offers.one? }
    assert models.all? { |model| model.reload.mesh_analysis_status == "passed" }
    assert_equal 50, enqueued_jobs.count { |job| job.fetch(:job) == AnalyzeModelMeshJob }
    assert_equal 50, catalog_import.model_snapshots.length
  end

  test "rollback removes every unchanged draft and preserves the batch record" do
    catalog_import = CatalogImports::Importer.call(designers(:one), catalog_archive)

    removed = CatalogImports::Rollback.call(catalog_import)

    assert_equal 2, removed
    assert_empty catalog_import.reload.models3d
    assert_predicate catalog_import, :rolled_back?
    assert_nothing_raised { AnalyzeModelMeshJob.perform_now(catalog_import.model_snapshots.keys.first) }
  end

  test "rollback refuses the whole batch when a draft changed" do
    catalog_import = CatalogImports::Importer.call(designers(:one), catalog_archive)
    catalog_import.models3d.first.update!(title: "Edited after import")

    error = assert_raises(CatalogImports::Error) { CatalogImports::Rollback.call(catalog_import) }

    assert_includes error.message, "changed or published drafts"
    assert_equal 2, catalog_import.reload.models3d.count
    assert_predicate catalog_import, :active?
  end

  test "a missing referenced file leaves no partial batch or models" do
    before_models = Model3d.count

    error = assert_raises(CatalogImports::Error) do
      CatalogImports::Importer.call(
        designers(:one), catalog_archive(missing_path: "models/model-2.stl")
      )
    end

    assert_includes error.message, "missing file models/model-2.stl"
    assert_equal before_models, Model3d.count
    assert_equal 0, CatalogImport.count
  end
end
