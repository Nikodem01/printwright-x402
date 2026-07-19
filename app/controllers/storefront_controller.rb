class StorefrontController < ApplicationController
  allow_unauthenticated_access

  def index
    @query = params[:q]
    scope = Model3d.published.includes(:designer, :license_offers, model_files: { file_attachment: :blob })
    scope = scope.search(@query) if @query.present?
    scope = scope.where("printability -> 'materials' ? :m", m: params[:material]) if params[:material].present?
    scope = scope.where("(printability ->> 'supports')::boolean = false") if params[:supports_free].present?
    if params[:max_price_cents].present?
      affordable = LicenseOffer.where(price_cents: ..params[:max_price_cents].to_i).select(:model3d_id)
      scope = scope.where(id: affordable)
    end
    @models = scope
  end

  def show
    @model = Model3d.published.includes(:designer, :license_offers,
                                        model_files: { file_attachment: :blob }).find_by!(slug: params[:slug])
    @licenses_issued = License.joins(purchase: :license_offer)
                              .where(license_offers: { model3d_id: @model.id }).count
  end
end
