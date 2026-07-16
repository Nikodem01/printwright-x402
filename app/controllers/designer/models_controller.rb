class Designer::ModelsController < Designer::BaseController
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

    digest = Digest::SHA256.new
    files.sort_by { |f| f.file.filename.to_s }.each { |f| digest.update(f.file.download) }
    @model.update!(file_hash: "sha256:#{digest.hexdigest}", status: "published")
    redirect_to model_page_path(@model.slug), notice: "Published — live in the catalog and buyable by agents."
  end

  private

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

  def attach_uploads
    Array(params.dig(:model3d, :printable_files)).reject(&:blank?).each do |upload|
      kind = upload.original_filename.split(".").last.to_s.downcase
      file = @model.model_files.create!(kind: ModelFile::KINDS.include?(kind) ? kind : "stl",
                                        position: @model.model_files.count)
      file.file.attach(upload)
    end
    Array(params.dig(:model3d, :render_files)).reject(&:blank?).each do |upload|
      file = @model.model_files.create!(kind: "render", position: @model.model_files.count)
      file.file.attach(upload)
    end
  end
end
