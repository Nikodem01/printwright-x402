require "test_helper"

# V12: the buy flow must pass the full terms visibly, the API must serve
# text + permalink, and publishing requires the recorded designer warranty.
class TermsSurfacesTest < ActionDispatch::IntegrationTest
  setup do
    @model = Model3d.create!(
      designer: designers(:one), title: "Terms Cube", slug: "terms-cube",
      status: "published", file_hash: "sha256:abc"
    )
    @offer = @model.license_offers.create!(kind: "personal", price_cents: 250)
  end

  test "model page renders the full license text before purchase" do
    get model_page_path(@model.slug)
    assert_response :success
    version = Licensing::Documents::CURRENT_VERSION
    assert_match "License terms — personal (#{version})", response.body
    assert_match "Printwright Personal Print License", response.body
    assert_match "honesty clause", response.body
    assert_select "a[href=?]", license_document_path(version: version, kind: "personal")
  end

  test "API model details serve terms text, hash, and permalink" do
    get "/api/v1/models/#{@model.id}", headers: { accept: "application/json" }
    terms = response.parsed_body["license_offers"].first["terms"]
    version = Licensing::Documents::CURRENT_VERSION
    assert_equal version, terms["version"]
    assert_equal Licensing::Documents.hash(version, "personal"), terms["hash"]
    assert_includes terms["url"], "/license/#{version}/personal"
    assert_includes terms["text"], "Personal Print License"
  end

  test "legal pages render with honest template labels" do
    { terms_path => "Marketplace Terms of Service",
      privacy_path => "permanently", takedown_path => "counter-notice" }.each do |path, marker|
      get path
      assert_response :success
      assert_match marker, response.body
      assert_match(/[Tt]emplate/, response.body)
    end
  end

  test "publish without the warranty checkbox is refused and records nothing" do
    draft = Model3d.create!(designer: designers(:two), title: "Draft", slug: "warranty-draft")
    draft.license_offers.create!(kind: "personal", price_cents: 100)
    stl = draft.model_files.create!(kind: "stl", position: 0)
    stl.file.attach(
      io: File.open(Rails.root.join("db/seed_assets/calibration-cube.stl"), "rb"),
      filename: "calibration-cube.stl", content_type: "model/stl"
    )
    sign_in_as designers(:two)

    token = Models::PublishReview.token(draft)
    post publish_designer_model_path(draft), params: { review_token: token }
    assert_redirected_to edit_designer_model_path(draft)
    assert draft.reload.status == "draft"
    assert_nil draft.warranty_accepted_at

    AnalyzeModelMeshJob.perform_now(draft.id)
    post review_designer_model_path(draft), params: { model3d: { title: draft.title } }
    token = css_select("input[name='review_token']").sole["value"]
    post publish_designer_model_path(draft), params: { warranty: "1", review_token: token }
    assert draft.reload.published?
    assert_not_nil draft.warranty_accepted_at
  end
end
