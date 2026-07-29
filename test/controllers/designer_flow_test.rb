require "test_helper"
require "webmock/minitest"
require_relative "../test_helpers/mesh_test_helper"

class DesignerFlowTest < ActionDispatch::IntegrationTest
  include MeshTestHelper

  setup do
    # Signup checks the password against Have I Been Pwned; keep the suite offline
    # and deterministic by stubbing it "not breached".
    stub_request(:get, %r{api\.pwnedpasswords\.com/range/}).to_return(status: 200, body: "")
  end

  test "sign up -> upload -> publish makes the model live and API-buyable-shaped" do
    post "/create-account", params: {
      display_name: "Flow Studio", email: "flow@example.com",
      password: "verdigris-kettle-9-monsoon", hedera_account_id: "0.0.42"
    }
    assert_redirected_to designer_root_path

    stl = fixture_file_upload(Rails.root.join("db/seed_assets/calibration-cube.stl"), "model/stl")
    render_png = fixture_file_upload(Rails.root.join("db/seed_assets/calibration-cube.png"), "image/png")
    post designer_models_path, params: { model3d: {
      title: "Flow Test Widget", tags_text: "widget, flow",
      description: "Uploaded through the real form.",
      category: "workshop-tools", collections: %w[support-free-essentials maker-basics],
      printability: { supports: "false", materials_text: "PLA", est_print_minutes: "30" },
      printable_files: [ stl ], render_files: [ render_png ],
      license_offers_attributes: { "0" => { kind: "personal", price_cents: "150", terms_md: "T." } }
    } }
    model = Model3d.find_by!(slug: "flow-test-widget")
    assert_redirected_to edit_designer_model_path(model)
    assert model.draft?
    assert_equal %w[widget flow], model.tags
    assert_equal "workshop-tools", model.category
    assert_equal %w[support-free-essentials maker-basics], model.collections
    assert_equal false, model.printability["supports"]
    assert model.model_files.count == 2
    offer = model.license_offers.sole
    assert_equal Licensing::Documents::CURRENT_VERSION, offer.terms_version
    assert_equal Licensing::Documents.hash(Licensing::Documents::CURRENT_VERSION, "personal"), offer.terms_hash
    assert_not_equal "T.", offer.terms_text

    get edit_designer_model_path(model)
    assert_response :success
    assert_select "textarea[name*='terms_md']", count: 0
    assert_select "details", text: /Personal Print License/
    assert_select "form[action='/verify-account-resend'][method='post']" do
      assert_select "input[name='email'][value='flow@example.com']"
      assert_select "button", text: "Send verification email"
    end

    patch designer_model_path(model), params: { model3d: {
      title: model.title,
      license_offers_attributes: { "0" => { id: offer.id, kind: "personal",
        price_cents: "150", terms_md: "Injected custom terms." } }
    } }
    assert_redirected_to edit_designer_model_path(model)
    assert_not_equal "Injected custom terms.", offer.reload.terms_text

    AnalyzeModelMeshJob.perform_now(model.id)
    assert_equal "passed", model.reload.mesh_analysis_status

    # Publishing is gated on a verified email (S2); simulate clicking the link.
    Designer.find_by!(email_address: "flow@example.com").account_verified!

    post review_designer_model_path(model), params: { model3d: { title: model.title } }
    assert_response :success
    review_token = css_select("input[name='review_token']").sole["value"]

    assert_enqueued_with(job: RenderModelJob, args: [ model.id ]) do
      post publish_designer_model_path(model), params: { warranty: "1", review_token: review_token }
    end
    follow_redirect!
    assert_select ".flash-ok", text: /Buyer payments settle to Printwright.*90% share remains owed.*Payouts.*proved and verified/m
    assert_not Designer.find_by!(email_address: "flow@example.com").payout_account_verified?
    assert_not_requested :get, %r{mirrornode\.hedera\.com/api/v1/accounts/0\.0\.42}
    model.reload
    assert model.published?
    assert_match(/\Asha256:[0-9a-f]{64}\z/, model.file_hash)
    assert_equal %w[stl], model.printable_files.map(&:kind)

    get api_v1_models_url(q: "flow widget")
    assert_equal model.id, response.parsed_body["models"].first["id"]

    get api_v1_model_url(model)
    assert_equal "workshop-tools", response.parsed_body["category"]
    assert_equal %w[support-free-essentials maker-basics], response.parsed_body["collections"]

    get category_path("workshop-tools")
    assert_select ".model-card", text: /Flow Test Widget/, count: 1
    get collection_path("maker-basics")
    assert_select ".model-card", text: /Flow Test Widget/, count: 1

    get model_page_path(model.slug)
    assert_response :success
    assert_match "Personal Print License", response.body
    assert_no_match "Injected custom terms", response.body
  end

  test "publish refuses without files and without offers" do
    designer = designers(:one)
    sign_in_as designer
    model = designer.models3d.create!(title: "Bare", slug: "bare-#{SecureRandom.hex(3)}")
    post review_designer_model_path(model), params: { model3d: { title: model.title } }
    assert model.reload.draft?
    follow_redirect!
    assert_select ".flash-bad", text: /printable file/
  end

  test "review saves the complete draft and shows the exact publish snapshot" do
    designer = designers(:one)
    designer.update!(hedera_account_id: "0.0.42")
    designer.update!(payout_account_verified_at: Time.current)
    model = designer.models3d.create!(title: "Before review", slug: "before-review")
    offer = model.license_offers.create!(kind: "personal", price_cents: 100)
    attach_stl(model, box_stl, filename: "reviewed.stl")
    AnalyzeModelMeshJob.perform_now(model.id)
    sign_in_as designer

    post review_designer_model_path(model), params: { model3d: {
      title: "Exact reviewed title", description: "Exact reviewed description",
      tags_text: "reviewed, exact",
      category: "desk-organization", collections: [ "small-space" ],
      printability: { supports: "false", materials_text: "PLA PETG", est_print_minutes: "45" },
      license_offers_attributes: { "0" => { id: offer.id, kind: "personal",
        price_cents: "250", max_units: "12" } }
    } }

    assert_response :success
    assert_select "h1", text: "Review and publish"
    assert_select "[data-review-field='title']", text: "Exact reviewed title"
    assert_select "[data-review-field='description']", text: "Exact reviewed description"
    assert_select "[data-review-field='category']", text: "Desk organization"
    assert_select "[data-review-field='collections']", text: "Small-space wins"
    assert_select "[data-review-field='file']", text: /reviewed\.stl/
    assert_select "[data-review-field='license']", text: /Personal.*2\.50 USDC.*2\.25 USDC/m
    assert_select "[data-review-field='license']", text: /preferred checkout quote.*USDC first/m
    assert_select "[data-review-field='payout']", text: /0\.0\.42.*verified/m
    assert_select "input[name='review_token'][type='hidden']", 1
    assert_select "input[name='warranty'][type='checkbox']", 1
    assert_equal "Exact reviewed title", model.reload.title
    assert_equal %w[reviewed exact], model.tags
    assert_equal "desk-organization", model.category
    assert_equal %w[small-space], model.collections
    assert_equal 250, model.license_offers.sole.price_cents
    assert model.draft?
  end

  test "designer taxonomy controls use stable keys, clear collections, and reject unknown values" do
    designer = designers(:one)
    model = designer.models3d.create!(
      title: "Controlled discovery", slug: "controlled-discovery-#{SecureRandom.hex(3)}",
      category: "desk-organization", collections: %w[small-space]
    )
    sign_in_as designer

    get edit_designer_model_path(model)
    assert_response :success
    assert_select "select[name='model3d[category]'] option", Model3d::CATEGORIES.length + 1
    assert_select "input[type='text'][name='model3d[category]']", count: 0
    Model3d::CATEGORIES.each do |key, definition|
      assert_select "option[value=?]", key, text: definition.fetch(:name)
    end
    Model3d::COLLECTIONS.each do |key, definition|
      assert_select "input[type='checkbox'][name='model3d[collections][]'][value=?]", key
      assert_select "label", text: /#{Regexp.escape(definition.fetch(:name))}/
    end
    assert_select ".editor-preview-discovery-note", text: /buyer.*query.*relevance/i

    patch designer_model_path(model), params: { model3d: {
      title: model.title, category: "workshop-tools", collections: [ "" ]
    } }
    assert_redirected_to edit_designer_model_path(model)
    assert_equal "workshop-tools", model.reload.category
    assert_empty model.collections

    patch designer_model_path(model), params: { model3d: {
      title: model.title, category: "made-up", collections: %w[maker-basics made-up]
    } }
    assert_response :unprocessable_entity
    assert_select ".flash-bad", text: /Category is not included.*Collections contains an unknown collection/i
    assert_equal "workshop-tools", model.reload.category
    assert_empty model.collections
  end

  test "publish requires the current signed review snapshot" do
    designer = designers(:one)
    model = designer.models3d.create!(title: "Guarded", slug: "guarded")
    model.license_offers.create!(kind: "personal", price_cents: 100)
    attach_stl(model, box_stl, filename: "guarded.stl")
    AnalyzeModelMeshJob.perform_now(model.id)
    sign_in_as designer

    post publish_designer_model_path(model), params: { warranty: "1" }
    assert_redirected_to edit_designer_model_path(model)
    assert model.reload.draft?
    follow_redirect!
    assert_select ".flash-bad", text: /review this exact listing before publishing/i

    token = Models::PublishReview.token(model)
    model.update!(title: "Changed after review")
    post publish_designer_model_path(model), params: { warranty: "1", review_token: token }
    assert_redirected_to edit_designer_model_path(model)
    assert model.reload.draft?
    follow_redirect!
    assert_select ".flash-bad", text: /changed after review/i
  end

  test "designer pauses, resumes, retires, and safely restores a live listing" do
    designer = designers(:one)
    model = designer.models3d.create!(
      title: "Lifecycle", slug: "lifecycle-#{SecureRandom.hex(4)}", status: "published",
      file_hash: "sha256:#{'a' * 64}"
    )
    model.license_offers.create!(kind: "personal", price_cents: 100)
    sign_in_as designer

    get edit_designer_model_path(model)
    assert_select "form[action=?]", pause_designer_model_path(model)
    assert_select "form[action=?]", retire_designer_model_path(model)

    patch pause_designer_model_path(model)
    assert_predicate model.reload, :paused?
    follow_redirect!
    assert_select ".flash-ok", text: /hidden from discovery and new checkout.*existing buyer receipts.*downloads/m
    assert_select "form[action=?]", resume_designer_model_path(model)
    assert_select "form[action=?]", retire_designer_model_path(model)
    assert_select "button", text: "Review and publish", count: 0

    patch resume_designer_model_path(model)
    assert_predicate model.reload, :published?

    patch retire_designer_model_path(model)
    assert_predicate model.reload, :retired?
    follow_redirect!
    assert_select ".flash-ok", text: /public status page and existing buyer rights remain available/i
    assert_select "form[action=?]", restore_designer_model_path(model)
    assert_select "input[type=file][name='model3d[printable_files][]']", count: 0

    patch restore_designer_model_path(model)
    assert_predicate model.reload, :paused?
  end

  test "designer cannot change another studio's listing availability" do
    model = designers(:one).models3d.create!(
      title: "Owned elsewhere", slug: "owned-elsewhere-#{SecureRandom.hex(4)}", status: "published"
    )
    sign_in_as designers(:two)

    patch pause_designer_model_path(model)

    assert_response :not_found
    assert_predicate model.reload, :published?
  end

  test "designer can restart only their own draft analysis without touching a certified listing" do
    designer = designers(:one)
    draft = designer.models3d.create!(
      title: "Retry analysis", slug: "retry-analysis-#{SecureRandom.hex(3)}",
      mesh_analysis_status: "failed", mesh_analysis: { "errors" => [ "thin wall" ] },
      mesh_analysis_digest: "sha256:old", geometry_hash: "sha256:geometry"
    )
    attach_stl(draft, box_stl, filename: "retry.stl")
    published = designer.models3d.create!(
      title: "Certified analysis", slug: "certified-analysis-#{SecureRandom.hex(3)}",
      status: "published", mesh_analysis_status: "passed",
      mesh_analysis_digest: "sha256:certified", file_hash: "sha256:certified"
    )
    attach_stl(published, box_stl, filename: "certified.stl")
    sign_in_as designer

    get edit_designer_model_path(draft)
    assert_select "a[href=?][data-turbo-method='post']", retry_analysis_designer_model_path(draft),
      text: "Run analysis again"

    assert_enqueued_with(job: AnalyzeModelMeshJob, args: [ draft.id ]) do
      post retry_analysis_designer_model_path(draft)
    end
    assert_redirected_to edit_designer_model_path(draft, anchor: "files")
    assert_equal "pending", draft.reload.mesh_analysis_status
    assert_empty draft.mesh_analysis
    assert_nil draft.mesh_analysis_digest
    assert_nil draft.geometry_hash

    assert_no_enqueued_jobs only: AnalyzeModelMeshJob do
      post retry_analysis_designer_model_path(published)
    end
    assert_redirected_to edit_designer_model_path(published, anchor: "files")
    assert_equal "passed", published.reload.mesh_analysis_status
    assert_equal "sha256:certified", published.mesh_analysis_digest
    assert_equal "sha256:certified", published.file_hash

    other = designers(:two).models3d.create!(
      title: "Other analysis", slug: "other-analysis-#{SecureRandom.hex(3)}",
      mesh_analysis_status: "failed"
    )
    assert_no_enqueued_jobs only: AnalyzeModelMeshJob do
      post retry_analysis_designer_model_path(other)
    end
    assert_response :not_found
    assert_equal "failed", other.reload.mesh_analysis_status
  end

  test "designer change to a sold offer creates a future revision and preserves buyer history" do
    designer = designers(:one)
    model = designer.models3d.create!(title: "Reserved terms", slug: "reserved-terms",
      status: "published")
    offer = model.license_offers.create!(kind: "personal", price_cents: 100)
    purchase = Purchase.create!(license_offer: offer, status: "delivered",
      amount_base_units: "1000000", asset: X402::Requirements.usdc_asset,
      replay_key: SecureRandom.hex(32))
    license = License.allocate!(purchase)
    license.update!(cert_json: { "terms_hash" => offer.terms_hash })
    original_hash = offer.terms_hash
    sign_in_as designer

    patch designer_model_path(model), params: { model3d: {
      title: model.title,
      license_offers_attributes: { "0" => { id: offer.id, kind: "commercial_unit",
        price_cents: "999", max_units: "1" } }
    } }

    assert_redirected_to edit_designer_model_path(model)
    follow_redirect!
    assert_select ".flash-ok", text: /new offer revision is active for future buyers/i
    offer.reload
    assert_equal "personal", offer.kind
    assert_equal 100, offer.price_cents
    assert_equal original_hash, offer.terms_hash
    assert_not offer.active?
    revision = model.reload.license_offers.sole
    assert_equal 2, revision.revision
    assert_equal offer, revision.supersedes
    assert_equal "commercial_unit", revision.kind
    assert_equal 999, revision.price_cents
    assert_equal 1, revision.max_units
    assert_equal offer, purchase.reload.license_offer
    assert_equal original_hash, license.reload.cert_json.fetch("terms_hash")

    get api_v1_model_path(model)
    terms = response.parsed_body.fetch("license_offers").sole.fetch("terms")
    assert_equal Licensing::Documents::CURRENT_VERSION, terms.fetch("version")
    assert_equal Licensing::Documents.hash(Licensing::Documents::CURRENT_VERSION, "commercial_unit"), terms.fetch("hash")
    assert_includes terms.fetch("text"), "Commercial Per-Unit Print License"
  end

  test "license editor uses readable products, decimal USDC, net, and optional add state" do
    designer = designers(:one)
    model = designer.models3d.create!(title: "Readable offers", slug: "readable-offers")
    model.license_offers.create!(kind: "personal", price_cents: 250)
    sign_in_as designer

    get edit_designer_model_path(model)

    assert_response :success
    assert_select ".editor-license-card[data-license-state='active']", text: /Personal use.*2\.25 USDC/m
    assert_select ".editor-license-card[data-license-state='available'] summary",
      text: /Add Commercial per-unit license/
    assert_select "input[name$='[price_usdc]'][value='2.50'][step='0.01']", 1
    assert_select "input[name$='[price_cents]']", 0
    assert_select "select[name$='[kind]']", 0
    assert_select ".editor-license-card[data-license-state='active'] select[name$='[currency]'] option[value='USDC'][selected]", 1
    assert_select "label", text: /Preferred checkout quote.*USDC first.*HBAR first/m
    assert_select ".editor-license-card", text: /one physical print for commercial sale/
    assert_select ".editor-license-card", text: /does not change.*usage rights/m
    assert_select ".editor-license-card", text: /exact USDC and HBAR settlement options.*appears first.*does not change.*estimated share/m
  end

  test "new listing rejects a dollar price with more than two decimal places" do
    designer = designers(:one)
    sign_in_as designer

    assert_no_difference -> { Model3d.count } do
      post designer_models_path, params: { model3d: {
        title: "Invalid precision",
        license_offers_attributes: {
          "0" => { kind: "personal", price_usdc: "2.345" }
        }
      } }
    end

    assert_response :unprocessable_entity
    assert_select ".flash-bad", text: /price cents is not a number/i
    assert_select "input[name$='[price_usdc]'][value='2.345']", 1
  end

  test "designer adds and removes license products while cents callers remain compatible" do
    designer = designers(:one)
    model = designer.models3d.create!(title: "Product controls", slug: "product-controls")
    personal = model.license_offers.create!(kind: "personal", price_cents: 250)
    sign_in_as designer

    patch designer_model_path(model), params: { model3d: {
      title: model.title,
      license_offers_attributes: {
        "0" => { id: personal.id, kind: "personal", price_usdc: "2.50", _destroy: "1" },
        "1" => { kind: "commercial_unit", price_usdc: "4.75", currency: "HBAR", max_units: "12" }
      }
    } }

    assert_redirected_to edit_designer_model_path(model)
    offer = model.reload.license_offers.sole
    assert_equal "commercial_unit", offer.kind
    assert_equal 475, offer.price_cents
    assert_equal "HBAR", offer.currency
    assert_equal 12, offer.max_units
    assert_not LicenseOffer.exists?(personal.id)

    patch designer_model_path(model), params: { model3d: {
      title: model.title,
      license_offers_attributes: {
        "0" => { id: offer.id, kind: "commercial_unit", price_cents: "500" }
      }
    } }
    assert_equal 500, offer.reload.price_cents
  end

  test "published listing cannot remove its final future-buyer offer" do
    designer = designers(:one)
    model = designer.models3d.create!(
      title: "Always buyable while live", slug: "always-buyable", status: "published"
    )
    offer = model.license_offers.create!(kind: "personal", price_cents: 250)
    sign_in_as designer

    patch designer_model_path(model), params: { model3d: {
      title: model.title,
      license_offers_attributes: {
        "0" => { id: offer.id, kind: "personal", price_usdc: "2.50", _destroy: "1" }
      }
    } }

    assert_response :unprocessable_entity
    assert_select ".flash-bad", text: /Keep at least one license available.*Pause or retire/m
    assert offer.reload.active?
    assert_equal [ offer ], model.reload.license_offers.to_a
  end

  test "publish refuses a broken mesh with the analysis reason" do
    designer = designers(:one)
    sign_in_as designer
    model = designer.models3d.create!(title: "Broken upload", slug: "broken-upload")
    model.license_offers.create!(kind: "personal", price_cents: 100)
    lines = box_stl.lines
    attach_stl(model, (lines[0...-8] + [ lines.last ]).join, filename: "broken.stl")
    AnalyzeModelMeshJob.perform_now(model.id)

    post review_designer_model_path(model), params: { model3d: { title: model.title } }

    assert model.reload.draft?
    follow_redirect!
    assert_select ".flash-bad", text: /broken\.stl: is open/
  end

  test "publish refuses normalized geometry copied from another model" do
    original = designers(:one).models3d.create!(
      title: "Original geometry", slug: "original-geometry", status: "published"
    )
    attach_stl(original, box_stl, filename: "original.stl")
    AnalyzeModelMeshJob.perform_now(original.id)
    original.reload.update!(file_hash: original.mesh_analysis_digest)

    copy = designers(:two).models3d.create!(title: "Geometry copy", slug: "geometry-copy")
    copy.license_offers.create!(kind: "personal", price_cents: 100)
    attach_stl(copy, box_stl(offset: [ 20.0, -3.0, 4.0 ], reverse: true), filename: "copy.stl")
    AnalyzeModelMeshJob.perform_now(copy.id)
    sign_in_as designers(:two)

    post review_designer_model_path(copy), params: { model3d: { title: copy.title } }

    assert copy.reload.draft?
    follow_redirect!
    assert_select ".flash-bad", text: /matches existing published model “Original geometry”/
  end

  test "publish requeues analysis when the printable bundle changed" do
    designer = designers(:one)
    model = designer.models3d.create!(title: "Changed bundle", slug: "changed-bundle")
    model.license_offers.create!(kind: "personal", price_cents: 100)
    attach_stl(model, box_stl, filename: "first.stl")
    AnalyzeModelMeshJob.perform_now(model.id)
    analyzed_digest = model.reload.mesh_analysis_digest
    attach_stl(model, box_stl(width: 11), filename: "second.stl")
    sign_in_as designer

    assert_enqueued_with(job: AnalyzeModelMeshJob, args: [ model.id ]) do
      post review_designer_model_path(model), params: { model3d: { title: model.title } }
    end

    assert model.reload.draft?
    assert_nil model.mesh_analysis_digest
    assert_not_equal analyzed_digest, MeshAnalysis::Analyzer.bundle_digest(model.printable_files)
    follow_redirect!
    assert_select ".flash-bad", text: /analysis is running for this exact file bundle/i
  end

  test "designers cannot touch another designer's models" do
    sign_in_as designers(:two)
    model = designers(:one).models3d.create!(title: "Mine", slug: "mine-#{SecureRandom.hex(3)}")
    get edit_designer_model_path(model)
    assert_response :not_found
  end

  test "designer area requires authentication" do
    get designer_models_path
    assert_redirected_to "/login"
  end
end
