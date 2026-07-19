require "application_system_test_case"
require "webmock/minitest"

# The responsive gate (V26). A page that scrolls sideways on a phone is broken
# in a way screenshots at one width never catch, and it regresses silently —
# one `min-width` on a flex child is enough to do it. So it is a test, not an
# eyeball: every public surface, at every breakpoint we claim to support.
class ResponsiveTest < ApplicationSystemTestCase
  WIDTHS = [ 360, 768, 1280 ].freeze

  setup do
    designer = designers(:one)
    @model = Model3d.create!(
      designer: designer, title: "Responsive Fixture", slug: "responsive-fixture",
      description: "A model long enough to wrap onto several lines on a narrow screen.",
      file_hash: "sha256:#{Digest::SHA256.hexdigest('responsive')}", status: "published",
      printability: { "supports" => false, "materials" => [ "PETG" ], "bed_min_mm" => 20, "est_print_minutes" => 90 },
      tags: %w[cable clip organizer desk]
    )
    @model.license_offers.create!(kind: "personal", price_cents: 90, currency: "USDC", terms_md: "T.")
    stub_request(:get, %r{testnet\.mirrornode\.hedera\.com/api/v1/topics/.+/messages})
      .to_return(body: { messages: [] }.to_json)
  end

  test "no public page scrolls horizontally at any supported width" do
    paths = [
      [ "landing", root_path ],
      [ "model page", model_page_path(@model.slug) ],
      [ "designer profile", designer_path(designers(:one)) ],
      [ "api docs", docs_path ],
      [ "pricing", pricing_path ],
      [ "about", about_path ],
      [ "terms", terms_path ],
      [ "open books", open_books_path ],
      [ "agent sellers", agent_sellers_path ]
    ]

    WIDTHS.each do |width|
      resize_to(width)
      paths.each do |name, path|
        visit path
        overflow = page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")
        offenders = if overflow > 1
          page.evaluate_script(<<~JS)
            Array.from(document.querySelectorAll("body *"))
              .filter((element) => !element.closest(".table-scroll"))
              .filter((element) => element.getBoundingClientRect().right > document.documentElement.clientWidth + 1)
              .slice(0, 5)
              .map((element) => {
                const style = getComputedStyle(element);
                return `${element.tagName.toLowerCase()}.${element.className}: ${element.textContent.slice(0, 80)} ` +
                  `[white-space=${style.whiteSpace}, overflow-wrap=${style.overflowWrap}, word-break=${style.wordBreak}]`;
              })
              .join(", ")
          JS
        end
        assert_operator overflow, :<=, 1,
          "#{name} (#{path}) overflows by #{overflow}px at #{width}px wide: #{offenders}"
      end
    end
  end

  # Wide content (code blocks, endpoint tables) is allowed to scroll, but only
  # inside its own container — never by dragging the whole page sideways.
  test "docs keeps its wide code blocks in their own scroller" do
    resize_to(360)
    visit docs_path
    scrollable = page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll('pre')).filter(
        (el) => el.scrollWidth > el.clientWidth
      ).every((el) => getComputedStyle(el).overflowX === 'auto' || getComputedStyle(el).overflowX === 'scroll')
    JS
    assert scrollable, "a <pre> on /docs is wider than its box without being scrollable"
  end

  private

  def resize_to(width)
    page.driver.browser.manage.window.resize_to(width, 900)
  end
end
