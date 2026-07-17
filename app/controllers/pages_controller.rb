# Static site-legal pages. Templates, honestly labeled — reviewed text
# replaces them before any mainnet launch.
class PagesController < ApplicationController
  allow_unauthenticated_access

  def terms; end
  def privacy; end
  def takedown; end
  def badge; end
end
