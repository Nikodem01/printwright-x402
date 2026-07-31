# A capability link is a credential in URL form: whoever holds it can open a
# receipt or fetch a paid file, with no account and no further check. Such a URL
# must never reach an index or a crawl cache.
#
# `robots.txt` asks crawlers not to fetch these paths and a `<meta name=robots>`
# tag covers the HTML that renders. Neither covers a JSON body or a file
# download, and those are much of what these controllers actually return, so the
# instruction goes in a header instead.
#
# One known gap, measured rather than assumed: when Rodauth bounces an
# unauthenticated visitor it redirects out of the Rails response entirely, so
# that particular 302 loses this header. It carries no body, and its target is
# disallowed in robots.txt, so there is nothing there to index — every response
# that actually contains something keeps the header. Asserted both ways in
# test/integration/search_indexing_rules_test.rb.
module NoIndex
  extend ActiveSupport::Concern

  included { before_action :disallow_indexing }

  private

  def disallow_indexing
    response.set_header("X-Robots-Tag", "noindex, nofollow")
  end
end
