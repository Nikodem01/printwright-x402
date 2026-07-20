class StorefrontController < ApplicationController
  allow_unauthenticated_access

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
      affordable = LicenseOffer.where(price_cents: ..params[:max_price_cents].to_i).select(:model3d_id)
      scope = scope.where(id: affordable)
    end
    @models = @query.present? ? scope : scope.order(:title)
    assign_shopkeeper unless @catalog_definition
  end

  def show
    @model = Model3d.published.includes(:designer, :license_offers,
                                        model_files: { file_attachment: :blob }).find_by!(slug: params[:slug])
    @licenses_issued = License.joins(purchase: :license_offer)
                              .where(purchases: { sandbox: false },
                                     license_offers: { model3d_id: @model.id }).count
    @successful_prints = PrintReport.joins(license: { purchase: :license_offer })
                                    .where(license_offers: { model3d_id: @model.id }).count
  end

  private

  def assign_shopkeeper
    conversation = ChatConversation.active.find_by(id: session[:chat_conversation_id])
    @turns = conversation&.turns || []
    @purchase_proposal = conversation&.purchase_proposal&.deep_stringify_keys || {}
  end
end
