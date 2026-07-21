class DiscoveryController < ApplicationController
  def catalog
    expires_in 1.minute, public: true
    models = Model3d.published.includes(:designer, :license_offers).order(:slug)

    render json: {
      schema_version: 1,
      seller: {
        name: "Printwright",
        url: root_url,
        docs_url: docs_url,
        openapi_url: "#{request.base_url}/openapi.json"
      },
      x402: {
        version: 2,
        scheme: "exact",
        network: X402::Requirements.network
      },
      models: models.map { |model| catalog_model(model) }
    }
  end

  private

  def catalog_model(model)
    {
      id: model.id,
      slug: model.slug,
      title: model.title,
      description: model.description,
      category: model.category,
      collections: model.collections,
      designer: {
        name: model.designer.display_name,
        verified: model.designer.identity_verified?
      },
      page_url: model_page_url(model.slug),
      api_url: api_v1_model_url(model),
      offers: model.license_offers.map { |offer| catalog_offer(model, offer) }
    }
  end

  def catalog_offer(model, offer)
    {
      license_kind: offer.kind,
      price: {
        cents: offer.price_cents,
        amount: format("%.2f", offer.price_cents / 100.0),
        currency: "USD"
      },
      preferred_settlement_asset: offer.currency,
      settlement_assets: [ X402::Requirements.usdc_asset, X402::Requirements::HBAR_ASSET ],
      available: !offer.sold_out?,
      max_units: offer.max_units,
      remaining_units: offer.units_remaining,
      payment_url: api_v1_model_download_url(model_id: model.id, license: offer.kind),
      terms: catalog_terms(offer)
    }
  end

  def catalog_terms(offer)
    return { hash: offer.terms_hash } unless offer.terms_version

    {
      version: offer.terms_version,
      hash: offer.terms_hash,
      text_url: license_document_url(version: offer.terms_version, kind: offer.kind, format: :txt),
      permissions_url: license_document_url(version: offer.terms_version, kind: offer.kind, format: :json)
    }
  end
end
