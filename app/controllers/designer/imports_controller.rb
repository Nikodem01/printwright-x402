class Designer::ImportsController < Designer::BaseController
  rate_limit to: 3, within: 1.minute, only: :create, store: RateLimitStore

  def index
    @imports = current_designer.catalog_imports.order(created_at: :desc)
  end

  def new
  end

  def create
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
end
