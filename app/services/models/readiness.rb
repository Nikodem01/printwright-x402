module Models
  class Readiness
    Item = Data.define(:key, :label, :status, :detail, :required, :anchor) do
      def complete? = status == :complete
      def required? = required
    end

    attr_reader :model, :designer

    def initialize(model, designer)
      @model = model
      @designer = designer
    end

    def items
      @items ||= [
        email_item, title_item, printable_item, offer_item, analysis_item,
        description_item, render_item, discovery_item, guidance_item, payout_item
      ]
    end

    # Whether an item blocks publishing is a property of the item — the preview
    # image is only the designer's job when we cannot render one for them.
    def required_items = items.select(&:required?)
    def recommended_items = items.reject(&:required?)

    def required_complete_count = required_items.count(&:complete?)
    def required_count = required_items.size
    def ready_to_review? = required_items.all?(&:complete?)

    def review_blocker_message
      return "Verify your email before publishing." unless designer.email_verified?
      return "Attach at least one printable file first." unless printable_files?
      return analyzable_blocker if analyzable_blocker
      return "Add at least one license offer first." unless offers?
      return "Mesh analysis is running for this exact file bundle. Review again after it passes." if model.mesh_analysis_status == "pending"
      if model.mesh_analysis_status == "failed"
        return "Publish blocked: #{model.mesh_analysis_errors.join('; ')}"
      end
      unless render_files? || auto_renderable?
        return "Add a preview image before publishing — buyers decide from it, and we can only render one automatically from an STL."
      end

      nil
    end

    private

    def item(key, label, status, detail, required:, anchor:)
      Item.new(key:, label:, status:, detail:, required:, anchor:)
    end

    def email_item
      complete = designer.email_verified?
      item(:email, "Email verified", complete ? :complete : :blocked,
        complete ? "Account email confirmed." : "Required before publishing.",
        required: true, anchor: "listing-readiness")
    end

    def title_item
      complete = model.title.present?
      item(:title, "Listing title", complete ? :complete : :blocked,
        complete ? "Ready for the storefront." : "Add a clear buyer-facing title.",
        required: true, anchor: "details")
    end

    def printable_item
      detail = if !printable_files?
        "Attach an STL or 3MF file. CAD sources such as STEP can ship alongside it."
      elsif analyzable_blocker
        analyzable_blocker
      end
      item(:printable, "Printable bundle", detail ? :blocked : :complete,
        detail || "At least one attached STL or 3MF file.",
        required: true, anchor: "files")
    end

    def offer_item
      complete = offers?
      item(:offer, "License and price", complete ? :complete : :blocked,
        complete ? "At least one active offer is configured." : "Add a license offer and price.",
        required: true, anchor: "license")
    end

    def analysis_item
      status, detail = if !printable_files?
        [ :blocked, "Waiting for a printable bundle." ]
      elsif model.mesh_analysis_status == "passed"
        [ :complete, "The current bundle passed mesh and duplicate checks." ]
      elsif model.mesh_analysis_status == "failed"
        [ :blocked, model.mesh_analysis_errors.join("; ").presence || "The current bundle failed analysis." ]
      else
        [ :working, "Checking the current bundle. You can keep editing while this runs." ]
      end
      item(:analysis, "File analysis", status, detail, required: true, anchor: "files")
    end

    def description_item
      complete = model.description.present?
      item(:description, "Description", complete ? :complete : :recommended,
        complete ? "Buyer-facing description added." : "Recommended: explain what the model does and what is included.",
        required: false, anchor: "details")
    end

    def render_item
      complete = render_files?
      needed = !complete && printable_files? && !auto_renderable?
      status = if complete
        :complete
      else
        needed ? :blocked : :recommended
      end
      detail = if complete
        "A storefront render is available."
      elsif needed
        "Add a preview image — buyers decide from it, and we can only render one automatically from an STL."
      else
        "Recommended: add a clear render for catalog cards. We will render one from your STL if you do not."
      end
      item(:render, "Preview image", status, detail, required: needed, anchor: "images")
    end

    def discovery_item
      complete = model.tags.any?
      item(:discovery, "Discovery tags", complete ? :complete : :recommended,
        complete ? "Search tags added." : "Recommended: add precise terms buyers may search for.",
        required: false, anchor: "details")
    end

    def guidance_item
      printability = model.printability || {}
      complete = Array(printability["materials"]).any? && printability["est_print_minutes"].present?
      item(:guidance, "Print guidance", complete ? :complete : :recommended,
        complete ? "Material and estimated print time added." : "Recommended: add material and print-time guidance.",
        required: false, anchor: "guidance")
    end

    def payout_item
      complete = designer.payout_account_verified?
      item(:payout, "Payout destination", complete ? :complete : :recommended,
        complete ? "Ready for eligible post-delivery payouts." : "Sales may go live; earnings stay held until payout setup is complete.",
        required: false, anchor: "payout-destination")
    end

    def printable_files?
      model.printable_files.any? { |file| file.file.attached? }
    end

    def render_files?
      model.render_files.any? { |file| file.file.attached? }
    end

    # A cover can only be rendered from an STL; without one the designer's own
    # image is the only thing a buyer will ever see.
    def auto_renderable?
      model.printable_files.any? { |file| file.kind == "stl" && file.file.attached? }
    end

    # Companion-only: the bundle must carry something the analyzer can read, or
    # the buyer receives files that were never geometry-checked.
    def analyzable_blocker
      return @analyzable_blocker if defined?(@analyzable_blocker)

      @analyzable_blocker = Uploads::Bundle.missing_analyzable_reason(
        model.printable_files.select { |file| file.file.attached? }
             .map { |file| { kind: file.kind, filename: file.file.filename.to_s } }
      )
    end

    def offers?
      model.license_offers.any? do |offer|
        !offer.marked_for_destruction? && offer.price_cents.present?
      end
    end
  end
end
