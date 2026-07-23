class Designer::ProtectionController < Designer::BaseController
  # The protection center: this studio's fingerprints, how often they blocked
  # a copy from publishing, and certificate-linked takedown evidence — read
  # only, entirely tenant-scoped.
  def show
    @models = current_designer.models3d.where.not(status: "draft").order(:title)

    # Aggregate defense counts only: how many OTHER uploads were blocked
    # against each of this studio's fingerprints. Never the attempter's
    # identity, title, or draft state — those are another studio's private
    # workspace data.
    ids = @models.map(&:id)
    @blocked_counts = if ids.any?
      Model3d.where.not(designer_id: current_designer.id)
        .where("(mesh_analysis->>'duplicate_model_id')::bigint IN (?)", ids)
        .group(Arel.sql("(mesh_analysis->>'duplicate_model_id')::bigint")).count
    else
      {}
    end

    @licenses_by_model = License.joins(purchase: :license_offer)
      .where(purchases: { status: "delivered", sandbox: false })
      .where(license_offers: { model3d_id: ids })
      .order(:serial)
      .group_by { |license| license.purchase.license_offer.model3d_id }
  end
end
