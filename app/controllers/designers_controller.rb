class DesignersController < ApplicationController
  allow_unauthenticated_access only: %i[new create show]

  def new
    @designer = Designer.new
  end

  # Public designer profile: display name, verified badge, bio, and the
  # published catalog. Never renders email_address/password_digest/payout
  # internals — those aren't loaded into any view local here.
  def show
    @designer = Designer.find(params[:id])
    @models = @designer.models3d.published
                        .includes(:license_offers, model_files: { file_attachment: :blob })
  end

  def create
    @designer = Designer.new(designer_params)
    if @designer.save
      start_new_session_for @designer
      redirect_to designer_models_path, notice: "Welcome to Printwright."
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def designer_params
    params.require(:designer).permit(:email_address, :password, :password_confirmation,
                                     :display_name, :bio, :hedera_account_id)
  end
end
