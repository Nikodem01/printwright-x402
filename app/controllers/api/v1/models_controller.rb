class Api::V1::ModelsController < Api::V1::BaseController
  rate_limit to: 120, within: 1.minute, store: RateLimitStore, with: :api_rate_limited

  def index
    models = Model3d.published.includes(:designer, :license_offers, model_files: { file_attachment: :blob })
    models = models.search(params[:q]) if params[:q].present?
    models = models.where(category: params[:category]) if params[:category].present?
    models = models.where("? = ANY(collections)", params[:collection]) if params[:collection].present?
    models = models.where("printability -> 'materials' ? :m", m: params[:material]) if params[:material].present?
    if params[:supports].present? && %w[true false].include?(params[:supports])
      models = models.where("(printability ->> 'supports')::boolean = :s", s: params[:supports])
    end
    if params[:max_price_cents].present?
      # Subquery instead of joins+distinct: DISTINCT would clash with the
      # search scope's ORDER BY CASE expression on Postgres.
      affordable = LicenseOffer.where(price_cents: ..params[:max_price_cents].to_i).select(:model3d_id)
      models = models.where(id: affordable)
    end

    render json: { models: models.map { |m| model_summary(m) }, count: models.length }
  end

  def show
    model = Model3d.published.find(params[:id])
    render json: model_details(model)
  end

  private

  def model_summary(model)
    {
      id: model.id,
      slug: model.slug,
      title: model.title,
      category: model.category,
      collections: model.collections,
      designer: { name: model.designer.display_name },
      printability: model.printability,
      license_offers: model.license_offers.map do |offer|
        { kind: offer.kind, price_cents: offer.price_cents, currency: offer.currency }
      end,
      url: api_v1_model_url(model),
      render_url: render_url_for(model)
    }
  end

  def model_details(model)
    model_summary(model).merge(
      description: model.description,
      tags: model.tags,
      file_hash: model.file_hash,
      files: model.printable_files.map { |f| { kind: f.kind, filename: f.file.attached? ? f.file.filename.to_s : nil } },
      license_offers: model.license_offers.map do |offer|
        {
          kind: offer.kind,
          price_cents: offer.price_cents,
          currency: offer.currency,
          max_units: offer.max_units,
          terms: {
            version: offer.terms_version,
            hash: offer.terms_hash,
            url: offer.terms_version ? license_document_url(version: offer.terms_version, kind: offer.kind) : nil,
            permissions_url: offer.terms_version ?
              license_document_url(version: offer.terms_version, kind: offer.kind, format: :json) : nil,
            permissions: offer.terms_version ? Licensing::Permissions.document(offer.terms_version, offer.kind) : nil,
            text: offer.terms_text
          }
        }
      end,
      download_url: "#{api_v1_model_url(model)}/download?license={kind}",
      designer: {
        name: model.designer.display_name,
        verified: model.designer.identity_verified?,
        hedera_account_id: model.designer.hedera_account_id
      }
    )
  end

  def render_url_for(model)
    render_file = model.render_file
    return nil unless render_file&.file&.attached?
    request.base_url + rails_blob_path(render_file.file, only_path: true)
  end
end
