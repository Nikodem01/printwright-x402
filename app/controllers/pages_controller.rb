# Static site-legal pages. Templates, honestly labeled — reviewed text
# replaces them before any mainnet launch.
class PagesController < ApplicationController
  allow_unauthenticated_access

  def terms; end
  def privacy; end
  def takedown; end
  def badge; end
  def about; end
  def pricing; end

  def open_books
    @snapshot = OpenBooks::Snapshot.call
  end

  # Endpoint reference is rendered from the spec at request time, not
  # hand-duplicated, so the page and public/openapi.json can't drift apart.
  def docs
    @openapi = JSON.parse(Rails.root.join("public/openapi.json").read)
  end
end
