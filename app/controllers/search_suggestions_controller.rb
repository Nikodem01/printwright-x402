class SearchSuggestionsController < ApplicationController
  MAX_QUERY_LENGTH = 80

  rate_limit to: 60, within: 1.minute, store: RateLimitStore

  def index
    @query = params[:q].to_s.strip.first(MAX_QUERY_LENGTH)
    @models = suggestions_for(@query)
    render layout: false
  end

  private

  def suggestions_for(query)
    return Model3d.none if query.length < 2

    scope = Model3d.published.includes(:designer, :license_offers,
                                       model_files: { file_attachment: :blob })
    exact = scope.exact_search(query).limit(6).load
    exact.any? ? exact : scope.fuzzy_search(query).limit(6).load
  end
end
