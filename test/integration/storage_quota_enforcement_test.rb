require "test_helper"

# The quota unit test proves the arithmetic. This proves the thing that
# actually matters in production: a designer who hits the cap through the real
# upload form is turned away *cleanly* — told why, in a flash they can act on,
# with the over-quota file simply not stored. Not a 500, not a half-written
# record, and not a silent success that leaves the disk fuller than the cap.
class StorageQuotaEnforcementTest < ActionDispatch::IntegrationTest
  setup do
    @designer = designers(:one)
    sign_in_as @designer
    @stl = Rails.root.join("db/seed_assets/calibration-cube.stl")
  end

  teardown { restore_printwright }

  def upload_to(model)
    patch designer_model_path(model), params: { model3d: {
      printable_files: [ fixture_file_upload(@stl, "model/stl") ]
    } }
  end

  def draft_with_title(title)
    post designer_models_path, params: { model3d: {
      title: title, description: "d", category: "workshop-tools",
      license_offers_attributes: { "0" => { kind: "personal", price_cents: "150", terms_md: "T." } }
    } }
    Model3d.find_by(slug: title.parameterize)
  end

  test "an upload over the account allowance is refused with a flash and stores nothing" do
    model = draft_with_title("Quota Reject Widget")
    set_printwright(storage_bytes_per_designer: 100, storage_bytes_global: 1.gigabyte)

    upload_to(model)

    assert_redirected_to edit_designer_model_path(model)
    assert_match(/storage allowance/i, flash[:alert])
    assert_equal 0, model.reload.model_files.count, "the over-quota file must not be stored"
  end

  test "the global cap refuses the upload and names the deployment, not the designer" do
    model = draft_with_title("Global Cap Widget")
    set_printwright(storage_bytes_per_designer: 1.gigabyte, storage_bytes_global: 100)

    upload_to(model)

    assert_match(/total storage limit/i, flash[:alert])
    assert_equal 0, model.reload.model_files.count
  end

  test "under the cap the same upload succeeds, so the cap is what refused it" do
    model = draft_with_title("Quota Accept Widget")
    set_printwright(storage_bytes_per_designer: 1.gigabyte, storage_bytes_global: 1.gigabyte)

    upload_to(model)

    assert_nil flash[:alert]
    assert_equal 1, model.reload.model_files.count
  end

  test "hitting the model-count cap refuses the new model without raising" do
    draft_with_title("First Draft Widget")
    set_printwright(max_models_per_designer: @designer.models3d.count)

    post designer_models_path, params: { model3d: {
      title: "One Too Many", description: "d", category: "workshop-tools",
      license_offers_attributes: { "0" => { kind: "personal", price_cents: "150", terms_md: "T." } }
    } }

    assert_response :unprocessable_entity
    assert_select "body", /limit of \d+ models/i
    assert_nil Model3d.find_by(slug: "one-too-many")
  end
end
