class Designer::ModelsController < Designer::BaseController
  rate_limit to: 10, within: 1.minute, only: %i[create retry_analysis], store: RateLimitStore
  STATUS_FILTERS = %w[all published draft paused retired].freeze
  SORTS = {
    "recent" => { updated_at: :desc },
    "title" => { title: :asc },
    "oldest" => { created_at: :asc }
  }.freeze

  def index
    base = current_designer.models3d
    @status_counts = base.group(:status).count
    @status_counts["all"] = @status_counts.values.sum

    @status = STATUS_FILTERS.include?(params[:status]) ? params[:status] : "all"
    @query = params[:q].to_s.strip
    @sort = SORTS.key?(params[:sort]) ? params[:sort] : "recent"

    scope = @status == "all" ? base : base.where(status: @status)
    scope = scope.title_matching(@query) if @query.present?
    @models = scope.order(SORTS.fetch(@sort))
      .includes(:license_offers, model_files: { file_attachment: :blob })

    # One grouped query: delivered, non-sandbox sales per model over the
    # immutable ledger. No buyer identity is read.
    @sales_by_model = LedgerEntry.where(designer: current_designer, entry_kind: "designer_share")
      .joins(purchase: { license_offer: :model3d }).where(purchases: { status: "delivered" })
      .group("models3d.id").count
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
    revised_offer = apply_draft_changes!
    attach_uploads
    notice = revised_offer ?
      "Updated. A new offer revision is active for future buyers; past purchases keep the original." :
      "Updated."
    redirect_to edit_designer_model_path(@model), notice: notice
  rescue ActiveRecord::RecordInvalid => error
    @model.errors.add(:base, error.record.errors.full_messages.to_sentence) unless error.record == @model
    render :edit, status: :unprocessable_entity
  rescue ActiveRecord::RecordNotUnique
    @model.errors.add(:base, "Only one active offer of each license kind is allowed.")
    render :edit, status: :unprocessable_entity
  end

  def review
    @model = find_model
    return already_published unless @model.draft?

    apply_draft_changes!
    return redirect_to edit_designer_model_path(@model) if attach_uploads.any?

    @model.reload
    readiness = Models::Readiness.new(@model, current_designer)
    blocker = readiness.review_blocker_message
    return review_blocked(blocker) if blocker

    digest = MeshAnalysis::Analyzer.bundle_digest(attached_printable_files)
    if @model.mesh_analysis_digest != digest || @model.mesh_analysis_status == "pending"
      queue_mesh_analysis
      return review_blocked("Mesh analysis is running for this exact file bundle. Review again after it passes.")
    end
    if (duplicate = duplicate_model(digest))
      return review_blocked(
        "Publish blocked: matches existing published model “#{duplicate.title}”. Contact support if you are authorized to republish it."
      )
    end

    @snapshot = Models::PublishReview.snapshot(@model)
    @review_token = Models::PublishReview.token(@model, snapshot: @snapshot)
  rescue ActiveRecord::RecordInvalid => error
    @model.errors.add(:base, error.record.errors.full_messages.to_sentence) unless error.record == @model
    render :edit, status: :unprocessable_entity
  rescue ActiveRecord::RecordNotUnique
    @model.errors.add(:base, "Only one active offer of each license kind is allowed.")
    render :edit, status: :unprocessable_entity
  end

  # Publishing freezes the bundle hash: sha256 over the printable files'
  # bytes, sorted by filename, so the certificate anchor is deterministic.
  def publish
    @model = find_model
    unless Models::PublishReview.valid?(@model, params[:review_token])
      return redirect_to edit_designer_model_path(@model),
        alert: params[:review_token].present? ?
          "This listing changed after review. Review the current draft again before publishing." :
          "Review this exact listing before publishing."
    end
    unless current_designer.email_verified?
      return redirect_to edit_designer_model_path(@model),
        alert: "Verify your email before publishing — we sent a confirmation link when you signed up. Resend it from your inbox or the login page."
    end
    return already_published if @model.published?
    files = attached_printable_files
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

  def pause
    change_availability!(:pause,
      "Sales paused. The listing is hidden from discovery and new checkout; existing buyer receipts, certificates, downloads, and updates remain available.")
  end

  def resume
    change_availability!(:resume,
      "Sales resumed. The listing is discoverable and available for new checkout again.")
  end

  def retire
    change_availability!(:retire,
      "Listing retired. New discovery and checkout are off; its public status page and existing buyer rights remain available.")
  end

  def restore
    change_availability!(:restore,
      "Listing restored in a paused state. Review it, then resume sales when it is ready for new buyers.")
  end

  def retry_analysis
    @model = find_model
    unless @model.draft?
      return redirect_to edit_designer_model_path(@model, anchor: "files"),
        alert: "The certified bundle is frozen. File analysis can only be restarted for a draft bundle."
    end
    if attached_printable_files.empty?
      return redirect_to edit_designer_model_path(@model, anchor: "files"),
        alert: "Attach a printable file before restarting analysis."
    end

    queue_mesh_analysis
    redirect_to edit_designer_model_path(@model, anchor: "files"),
      notice: "File analysis restarted in the background. You can keep editing and refresh this status later."
  end

  private

  def apply_draft_changes!
    attributes = model_params
    offers = attributes.delete(:license_offers_attributes).to_h.values
    removing_offer = offers.any? do |offer|
      offer[:id].present? && ActiveModel::Type::Boolean.new.cast(offer[:_destroy])
    end
    revised_offer = false
    Model3d.transaction do
      @model.update!(attributes)
      offers.each do |offer|
        result = LicenseOffers::Reviser.call(model: @model, attributes: offer)
        revised_offer ||= result&.supersedes_id.present?
      end
      ensure_future_offer! if removing_offer
    end
    revised_offer
  end

  def attached_printable_files
    @model.printable_files.select { |file| file.file.attached? }
  end

  def already_published
    redirect_to edit_designer_model_path(@model),
      alert: "The certified bundle is frozen. Publish a version update instead."
  end

  def review_blocked(message)
    redirect_to edit_designer_model_path(@model), alert: message
  end

  def change_availability!(action, notice)
    @model = find_model
    Models::Availability.call(model: @model, action: action)
    redirect_to edit_designer_model_path(@model), notice: notice
  rescue Models::Availability::InvalidTransition => error
    redirect_to edit_designer_model_path(@model), alert: error.message.humanize
  end

  # Review establishes payout readiness; buyer settlement always goes to the
  # treasury. Designer payout is a separate post-delivery state machine.
  def publish_notice
    base = "Published — live in the catalog and buyable by agents."
    if current_designer.hedera_account_id.blank?
      return "#{base} Buyer payments settle to Printwright's treasury. Add a payout " \
        "destination in Payouts; your 90% share remains owed until it is verified."
    end

    if current_designer.payout_account_verified?
      "#{base} Buyer payments settle to Printwright's treasury. After delivery, your " \
        "90% share is queued for payout to #{current_designer.hedera_account_id}."
    else
      "#{base} Buyer payments settle to Printwright's treasury. Your 90% share remains " \
        "owed until the payout destination in Payouts is proved and verified for USDC."
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
    Models::AnalysisQueue.call(@model)
  end

  def ensure_future_offer!
    return unless @model.published?
    return if @model.license_offers.reload.any?

    @model.errors.add(:base,
      "Keep at least one license available on a published listing. Pause or retire it to stop all new sales.")
    raise ActiveRecord::RecordInvalid, @model
  end

  def model_params
    permitted = params.require(:model3d).permit(
      :title, :slug, :description, :tags_text, :category,
      collections: [],
      printability: %i[supports materials_text est_print_minutes bed_min_mm],
      license_offers_attributes: %i[id kind price_usdc price_cents currency max_units _destroy]
    )
    normalize(permitted)
  end

  # Text conveniences: comma-separated tags, space/comma materials, checkbox bool.
  def normalize(permitted)
    if (tags = permitted.delete(:tags_text))
      permitted[:tags] = tags.split(",").map(&:strip).reject(&:blank?)
    end
    if permitted.key?(:collections)
      permitted[:collections] = Array(permitted[:collections]).reject(&:blank?).uniq
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
    printable_uploads = Array(params.dig(:model3d, :printable_files)).reject(&:blank?)
    if !@model.draft? && printable_uploads.any?
      rejected << "the certified bundle is frozen; use Publish update"
      printable_uploads = []
    end
    printable_uploads.each do |upload|
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
    rejected
  end
end
