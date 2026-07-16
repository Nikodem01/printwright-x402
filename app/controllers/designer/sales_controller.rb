class Designer::SalesController < Designer::BaseController
  def index
    @purchases = Purchase.delivered
                         .joins(license_offer: :model3d)
                         .where(models3d: { designer_id: current_designer.id })
                         .includes(:license, license_offer: :model3d)
                         .order(created_at: :desc)
  end
end
