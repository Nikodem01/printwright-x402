class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  before_action :set_current_designer
  helper_method :current_designer, :authenticated?

  private

  # Public by default: pages don't require a session. Areas that need one call
  # `rodauth.require_account` in their base controller (designer/admin).
  def current_designer
    Current.designer
  end

  def authenticated?
    current_designer.present?
  end

  def set_current_designer
    Current.designer = rodauth.rails_account if rodauth.logged_in?
  end
end
