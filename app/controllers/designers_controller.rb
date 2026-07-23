class DesignersController < ApplicationController
  after_action :record_analytics, only: :show

  # Public designer profile: display name, verified badge, bio, and the
  # published catalog. Never renders email_address/password_digest/payout
  # internals — those aren't loaded into any view local here.
  def show
    @designer = Designer.find(params[:id])
    @models = (@designer.account_closed? ? Model3d.none : @designer.models3d.published)
                        .includes(:license_offers, model_files: { file_attachment: :blob })
    @analytics_event = {
      model_ids: @models.map(&:id), event: "impression", channel: "human", source: "profile"
    }
  end

  def verified_profile
    designer = Designer.find(params[:id])
    raise ActiveRecord::RecordNotFound unless designer.identity_verified?

    uri = ProfileVerifications::Fetcher.validate_uri!(designer.verified_profile_url)
    redirect_to uri.to_s, allow_other_host: true
  rescue ProfileVerifications::Fetcher::Error
    raise ActiveRecord::RecordNotFound
  end

  private

  def record_analytics
    Analytics::Recorder.record_later(**@analytics_event) if response.successful? && @analytics_event
  end
end
