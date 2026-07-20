module ApplicationHelper
  def storefront_cart_count
    StorefrontCart.new(session).count
  end

  def hashscan_tx_link(tx_id)
    return "" if tx_id.blank?
    link_to tx_id.truncate(22), "#{Hedera::Network.hashscan_base}/transaction/#{tx_id}", class: "mono"
  end

  # Ledger amounts are asset base units: USDC has 6 decimals, HBAR 8.
  def format_base_units(amount, asset)
    if asset == "0.0.0"
      "#{format('%.2f', amount / 100_000_000.0)} ℏ"
    else
      format("%.2f USDC", amount / 1_000_000.0)
    end
  end

  def format_usdc_cents(cents)
    format("%.2f USDC", cents / 100.0)
  end

  # Every offer has an exact USDC settlement option. HBAR remains available in
  # the x402 challenge, but the storefront keeps one stable price denomination.
  def offer_price(offer)
    format_usdc_cents(offer.price_cents)
  end

  # /docs renders openapi.json's response objects directly; some are shared
  # via $ref (NotFound, RateLimited) rather than inlined, so resolve those
  # before reading description/headers off them.
  def openapi_deref(spec, node)
    return node unless node.is_a?(Hash) && node["$ref"]
    spec.dig("components", "responses", node["$ref"].split("/").last)
  end

  # Human labels for known printability keys; any key we've never seen still
  # gets a humanized fallback, so a future printability field never renders
  # a raw db-column name or drops silently.
  PRINTABILITY_LABELS = {
    "supports" => "Supports",
    "bed_min_mm" => "Minimum bed",
    "est_print_minutes" => "Estimated print time",
    "materials" => "Materials"
  }.freeze

  def printability_label(key)
    PRINTABILITY_LABELS[key.to_s] || key.to_s.humanize
  end

  def printability_value(key, value)
    case key.to_s
    when "supports"
      value ? "Required" : "Not needed"
    when "bed_min_mm"
      "#{value} mm"
    when "est_print_minutes"
      format_print_minutes(value)
    when "materials"
      Array(value).join(", ")
    else
      value.is_a?(Array) ? value.join(", ") : value.to_s
    end
  end

  # 12 -> "12 min"; 60 -> "1 hr"; 90 -> "1 hr 30 min".
  def format_print_minutes(minutes)
    minutes = minutes.to_i
    return "#{minutes} min" if minutes < 60

    hours, mins = minutes.divmod(60)
    parts = [ "#{hours} hr#{'s' unless hours == 1}" ]
    parts << "#{mins} min" if mins.positive?
    parts.join(" ")
  end
end
