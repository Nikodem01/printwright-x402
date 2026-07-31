class StorefrontController < ApplicationController
  after_action :record_analytics, only: %i[index show]

  def index
    @query = params[:q]
    @category_key = params[:category]
    @collection_key = params[:collection]
    @catalog_definition = Model3d.category_definition(@category_key) if @category_key.present?
    @catalog_definition = Model3d.collection_definition(@collection_key) if @collection_key.present?

    published = Model3d.published
    @category_counts = published.where.not(category: [ nil, "" ]).group(:category).count
    @collection_counts = Model3d::COLLECTIONS.keys.index_with do |collection|
      published.where("? = ANY(collections)", collection).count
    end

    scope = published.includes(:designer, :license_offers, model_files: { file_attachment: :blob })
    scope = scope.where(category: @category_key) if @category_key.present?
    scope = scope.where("? = ANY(collections)", @collection_key) if @collection_key.present?
    scope = scope.search(@query) if @query.present?
    scope = scope.where("printability -> 'materials' ? :m", m: params[:material]) if params[:material].present?
    scope = scope.where("(printability ->> 'supports')::boolean = false") if params[:supports_free].present?
    if params[:max_price_cents].present?
      affordable = LicenseOffer.active.where(price_cents: ..params[:max_price_cents].to_i).select(:model3d_id)
      scope = scope.where(id: affordable)
    end
    @models = @query.present? ? scope : scope.order(:title)
    assign_shopkeeper unless @catalog_definition
    @analytics_event = {
      model_ids: @models.map(&:id), event: "impression",
      channel: "human", source: impression_source
    }
  end

  def show
    @model = Model3d.publicly_resolvable.includes(:designer, :license_offers,
                                                  model_files: { file_attachment: :blob }).find_by!(slug: params[:slug])
    @successful_prints = PrintReport.joins(license: { purchase: :license_offer })
                                    .where(license_offers: { model3d_id: @model.id }).count
    @analytics_event = {
      model_ids: [ @model.id ], event: "view", channel: "human", source: "marketplace"
    }
  end

  private

  def assign_shopkeeper
    conversation = ChatConversation.active.find_by(id: session[:chat_conversation_id])
    @turns = conversation&.turns || []
    @purchase_proposal = conversation&.purchase_proposal&.deep_stringify_keys || {}
  end

  def impression_source
    return "search" if @query.present?
    return "category" if @category_key.present?
    return "collection" if @collection_key.present?

    "marketplace"
  end

  def record_analytics
    Analytics::Recorder.record_later(**@analytics_event) if response.successful? && @analytics_event
  end
end
