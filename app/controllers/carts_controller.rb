class CartsController < ApplicationController
  allow_unauthenticated_access

  before_action :load_cart

  def show; end

  def create
    offer = offer_from_params
    @cart.add!(offer, params[:quantity] || 1)
    redirect_back fallback_location: cart_path,
      notice: "Added #{offer.model3d.title} to your cart."
  rescue StorefrontCart::Invalid => error
    redirect_back fallback_location: cart_path, alert: error.message
  end

  def update
    offer = LicenseOffer.find(params.require(:offer_id))
    @cart.update!(offer, params.require(:quantity))
    redirect_to cart_path, notice: "Cart quantity updated."
  rescue StorefrontCart::Invalid => error
    redirect_to cart_path, alert: error.message
  end

  def remove
    @cart.remove!(params.require(:offer_id))
    redirect_to cart_path, notice: "Item removed from your cart."
  end

  def destroy
    @cart.clear!
    head :no_content
  end

  private

  def load_cart
    @cart = StorefrontCart.new(session)
  end

  def offer_from_params
    Model3d.published.find(params.require(:model_id)).license_offers.find_by!(kind: params.require(:license))
  end
end
