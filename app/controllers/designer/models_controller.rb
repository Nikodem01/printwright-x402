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

    digest = Digest::SHA256.new
    files.sort_by { |f| f.file.filename.to_s }.each { |f| digest.update(f.file.download) }
    @model.update!(file_hash: "sha256:#{digest.hexdigest}", status: "published",
                   warranty_accepted_at: Time.current)
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
    Array(params.dig(:model3d, :printable_files)).reject(&:blank?).each do |upload|
      ext = upload.original_filename.split(".").last.to_s.downcase
      kind = ModelFile::KINDS.include?(ext) ? ext : "stl"
      if (reason = Uploads::Validator.reason_to_reject(upload, kind: kind))
        rejected << reason
        next
      end
      file = @model.model_files.create!(kind: kind, position: @model.model_files.count)
      file.file.attach(upload)
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
  end
end
