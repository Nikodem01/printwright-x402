class Designer::BaseController < ApplicationController
  include NoIndex

  layout "designer"

  before_action -> { rodauth.require_account }
end
