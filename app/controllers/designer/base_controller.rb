class Designer::BaseController < ApplicationController
  layout "designer"

  private

  def current_designer
    Current.designer
  end
end
