class Designer::ModelsController < Designer::BaseController
  rate_limit to: 10, within: 1.minute, only: %i[create], store: RateLimitStore
  def index
    @models = current_designer.models3d.order(created_at: :desc)
  end

  def new
    @model = current_designer.models3d.build
    @model.license_offers.build(kind: "personal", price_cents: 250)
  end

  def create
    @model = current_designer.models3d.build(model_params)
    @model.slug = @model.title.to_s.parameterize if @model.slug.blank?
    if @model.save
      attach_uploads
      redirect_to edit_designer_model_path(@model), notice: "Saved as draft."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @model = find_model
  end

  def update
    @model = find_model
    if @model.update(model_params)
      attach_uploads
      redirect_to edit_designer_model_path(@model), notice: "Updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # Publishing freezes the bundle hash: sha256 over the printable files'
  # bytes, sorted by filename, so the certificate anchor is deterministic.
  def publish
    @model = find_model
    files = @model.printable_files.select { |f| f.file.attached? }
    return redirect_to edit_designer_model_path(@model), alert: "Attach at least one printable file first." if files.empty?
    return redirect_to edit_designer_model_path(@model), alert: "Add at least one license offer first." if @model.license_offers.none?
    unless params[:warranty] == "1"
      return redirect_to edit_designer_model_path(@model),
        alert: "Publishing requires the ownership warranty — every sold license names it."
    end

    digest = MeshAnalysis::Analyzer.bundle_digest(files)
    if @model.mesh_analysis_digest != digest || @model.mesh_analysis_status == "pending"
      queue_mesh_analysis
      return redirect_to edit_designer_model_path(@model),
        alert: "Mesh analysis is still running for this exact file bundle. Try Publish again after it passes."
    end
    if @model.mesh_analysis_status == "failed"
      return redirect_to edit_designer_model_path(@model),
        alert: "Publish blocked: #{@model.mesh_analysis_errors.join('; ')}"
    end

    duplicate = duplicate_model(digest)
    if duplicate
      return redirect_to edit_designer_model_path(@model),
        alert: "Publish blocked: matches existing published model “#{duplicate.title}”. Contact support if you are authorized to republish it."
    end

    PreviewMeshes::Attacher.call(@model)
    @model.update!(file_hash: digest, status: "published",
                   warranty_accepted_at: Time.current)
    RenderModelJob.perform_later(@model.id)
    redirect_to model_page_path(@model.slug), notice: publish_notice
  end

  private

  # Publish is the moment the payout destination gets decided, so the mirror
  # check runs here — and the notice says plainly where the money will go.
  def publish_notice
    base = "Published — live in the catalog and buyable by agents."
    return base if current_designer.hedera_account_id.blank?

    if current_designer.verify_payout_account!
      "#{base} Sales pay your Hedera account directly."
    else
      "#{base} Your Hedera account isn't ready to receive USDC yet — " \
        "sales are held in marketplace custody until it verifies."
    end
  end

  def find_model
    current_designer.models3d.find(params[:id])
  end

  def duplicate_model(digest)
    scope = Model3d.published.where.not(id: @model.id)
    scope.find_by(file_hash: digest) ||
      (@model.geometry_hash.present? && scope.find_by(geometry_hash: @model.geometry_hash))
  end

  def queue_mesh_analysis
    @model.update_columns(mesh_analysis_status: "pending", mesh_analysis_digest: nil,
                          geometry_hash: nil, mesh_analysis: {}, updated_at: Time.current)
    AnalyzeModelMeshJob.perform_later(@model.id)
  end

  def model_params
    permitted = params.require(:model3d).permit(
      :title, :slug, :description, :tags_text,
      printability: %i[supports materials_text est_print_minutes bed_min_mm],
      license_offers_attributes: %i[id kind price_cents max_units terms_md _destroy]
    )
    normalize(permitted)
  end

  # Text conveniences: comma-separated tags, space/comma materials, checkbox bool.
  def normalize(permitted)
    if (tags = permitted.delete(:tags_text))
      permitted[:tags] = tags.split(",").map(&:strip).reject(&:blank?)
    end
    if (printability = permitted[:printability])
      materials = printability.delete(:materials_text)
      printability[:materials] = materials.to_s.split(/[,\s]+/).reject(&:blank?) if materials
      printability[:supports] = ActiveModel::Type::Boolean.new.cast(printability[:supports])
      printability[:est_print_minutes] = printability[:est_print_minutes].presence&.to_i
      printability[:bed_min_mm] = printability[:bed_min_mm].presence&.to_i
      permitted[:printability] = printability.to_h.compact
    end
    permitted
  end

  # Every upload is content-checked (bytes, not filename) before it is
  # attached; rejects surface to the designer and never create records.
  def attach_uploads
    rejected = []
    printable_attached = false
    Array(params.dig(:model3d, :printable_files)).reject(&:blank?).each do |upload|
      ext = upload.original_filename.split(".").last.to_s.downcase
      kind = ModelFile::KINDS.include?(ext) ? ext : "stl"
      if (reason = Uploads::Validator.reason_to_reject(upload, kind: kind))
        rejected << reason
        next
      end
      file = @model.model_files.create!(kind: kind, position: @model.model_files.count)
      file.file.attach(upload)
      printable_attached = true
    end
    Array(params.dig(:model3d, :render_files)).reject(&:blank?).each do |upload|
      if (reason = Uploads::Validator.reason_to_reject(upload, kind: "render"))
        rejected << reason
        next
      end
      file = @model.model_files.create!(kind: "render", position: @model.model_files.count)
      file.file.attach(upload)
    end
    flash[:alert] = "Rejected: #{rejected.join('; ')}" if rejected.any?
    queue_mesh_analysis if printable_attached
  end
end
