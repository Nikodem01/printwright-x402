module ApplicationHelper
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
end
