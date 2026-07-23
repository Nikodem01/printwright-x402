class StorefrontCart
  MAX_ITEMS = 20
  Entry = Data.define(:offer, :quantity) do
    def subtotal_cents = offer.price_cents * quantity
  end

  class Invalid < StandardError; end

  def initialize(session)
    @session = session
    @quantities = session[:storefront_cart].to_h.transform_keys(&:to_s).transform_values(&:to_i)
  end

  def entries
    @entries ||= begin
      stored = LicenseOffer.joins(:model3d)
        .where(id: @quantities.keys, models3d: { status: "published" })
        .includes(model3d: [ :designer, { model_files: { file_attachment: :blob } } ])
        .index_by { |offer| offer.id.to_s }
      remapped = Hash.new(0)
      current_offers = {}
      @quantities.each do |offer_id, quantity|
        offer = stored[offer_id]
        next unless offer

        current = offer.active? ? offer : offer.model3d.license_offers.find_by(kind: offer.kind)
        if current
          remapped[current.id.to_s] += quantity
          current_offers[current.id.to_s] = current
        end
      end
      @quantities = remapped
      persist!
      remapped.map { |offer_id, quantity| Entry.new(offer: current_offers.fetch(offer_id), quantity: quantity) }
    end
  end

  def count = entries.sum(&:quantity)
  def total_cents = entries.sum(&:subtotal_cents)
  def empty? = entries.empty?

  def payment_items
    entries.flat_map do |entry|
      Array.new(entry.quantity) { { model_id: entry.offer.model3d_id, license: entry.offer.kind } }
    end
  end

  def add!(offer, quantity)
    quantity = normalized_quantity(offer, quantity)
    quantity += @quantities.fetch(offer.id.to_s, 0) if offer.kind == "commercial_unit"
    replace!(offer, quantity)
  end

  def update!(offer, quantity)
    raise Invalid, "That item is no longer in your cart." unless @quantities.key?(offer.id.to_s)

    replace!(offer, normalized_quantity(offer, quantity))
  end

  def remove!(offer_id)
    @quantities.delete(offer_id.to_s)
    persist!
  end

  def clear!
    @quantities = {}
    persist!
  end

  private

  def normalized_quantity(offer, value)
    quantity = Integer(value.to_s, 10)
    quantity = 1 if offer.kind == "personal"
    raise Invalid, "Quantity must be at least one." unless quantity.positive?

    quantity
  rescue ArgumentError, TypeError
    raise Invalid, "Quantity must be a whole number."
  end

  def replace!(offer, quantity)
    raise Invalid, "That listing is no longer available for new purchases." unless offer.model3d.published?

    limit = offer.kind == "personal" ? 1 : [ offer.units_remaining || MAX_ITEMS, MAX_ITEMS ].min
    raise Invalid, "Only #{limit} units remain for this offer." if quantity > limit

    candidate = @quantities.merge(offer.id.to_s => quantity)
    total = candidate.values.sum
    raise Invalid, "A cart can contain at most #{MAX_ITEMS} licenses." if total > MAX_ITEMS

    candidate_offers = LicenseOffer.active.includes(model3d: :designer).where(id: candidate.keys)
    payees = candidate_offers.map { |item| X402::Requirements.pay_to_for(item) }.uniq
    if payees.many?
      raise Invalid, "Those items do not share compatible payment requirements. Check out this cart first."
    end

    @quantities = candidate
    persist!
  end

  def persist!
    @session[:storefront_cart] = @quantities
    @entries = nil
  end
end
