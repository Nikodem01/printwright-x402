class Designer::BaseController < ApplicationController
  layout "designer"

  before_action -> { rodauth.require_account }
end
