class DesignersController < ApplicationController
  allow_unauthenticated_access only: %i[new create]

  def new
    @designer = Designer.new
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
