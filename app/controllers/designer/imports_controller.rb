class Designer::ImportsController < Designer::BaseController
  rate_limit to: 3, within: 1.minute, only: %i[preview create], store: RateLimitStore

  def index
    @imports = current_designer.catalog_imports.order(created_at: :desc)
  end

  def new
  end

  def preview
    @profile = CatalogImports::ProfileImporter.preview(params.require(:feed_url))
    render :new
  rescue CatalogImports::Error => error
    redirect_to new_designer_import_path, alert: "Profile refused: #{error.message}"
  end

  def create
    return create_from_profile if params[:profile_url].present?

    archive = params[:archive]
    return redirect_to new_designer_import_path, alert: "Choose a ZIP archive first." unless archive

    catalog_import = CatalogImports::Importer.call(current_designer, archive)
    redirect_to designer_imports_path,
      notice: "Imported #{catalog_import.model_count} publishable drafts. Mesh checks are queued."
  rescue CatalogImports::Error => error
    redirect_to new_designer_import_path, alert: "Import refused: #{error.message}"
  end

  def destroy
    catalog_import = current_designer.catalog_imports.find(params[:id])
    removed = CatalogImports::Rollback.call(catalog_import)
    redirect_to designer_imports_path, notice: "Rolled back #{removed} imported drafts."
  rescue CatalogImports::Error => error
    redirect_to designer_imports_path, alert: "Rollback refused: #{error.message}"
  end

  private

  def create_from_profile
    catalog_import = CatalogImports::ProfileImporter.call(
      current_designer,
      feed_url: params.require(:profile_url),
      expected_digest: params.require(:profile_digest),
      external_ids: params[:external_ids]
    )
    redirect_to designer_imports_path,
      notice: "Imported #{catalog_import.model_count} warranted external drafts with provenance. Mesh checks are queued."
  end
end
