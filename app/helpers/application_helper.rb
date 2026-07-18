module ApplicationHelper
  def hashscan_tx_link(tx_id)
    return "" if tx_id.blank?
    link_to tx_id.truncate(22), "#{Hedera::Network.hashscan_base}/transaction/#{tx_id}", class: "mono"
  end

  # Ledger amounts are asset base units: USDC has 6 decimals, HBAR 8.
  def format_base_units(amount, asset)
    if asset == "0.0.0"
      "#{format('%.2f', amount / 100_000_000.0)} ℏ"
    else
      format("$%.2f", amount / 1_000_000.0)
    end
  end

  # Prices are set in US cents; HBAR-lead offers settle in ℏ, so show the ℏ
  # amount (live rate) with the USD reference — never a bare "$" for an offer
  # that charges HBAR. Falls back to USD-only when no rate is available.
  def offer_price(offer)
    usd = format("$%.2f", offer.price_cents / 100.0)
    return usd unless offer.currency == "HBAR"

    tinybars = Hedera::ExchangeRate.tinybars_for_cents(offer.price_cents)
    return usd if tinybars.nil?
    "#{format('%.2f', tinybars / 100_000_000.0)} ℏ · #{usd}"
  end

  # /docs renders openapi.json's response objects directly; some are shared
  # via $ref (NotFound, RateLimited) rather than inlined, so resolve those
  # before reading description/headers off them.
  def openapi_deref(spec, node)
    return node unless node.is_a?(Hash) && node["$ref"]
    spec.dig("components", "responses", node["$ref"].split("/").last)
  end
end
