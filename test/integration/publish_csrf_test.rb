require "test_helper"

# The listing editor's "Review and publish" button submits the draft form to a
# different action than the form's own (`formaction` + `formmethod`). Rails 8.1
# defaults to per-form CSRF tokens, which are bound to the form's action and
# method, so a token minted for the form is rejected on the retargeted POST —
# and the whole test environment runs with forgery protection off, so nothing
# else here can see it. This test turns protection on and drives the real token
# out of the rendered page, the way a browser does.
class PublishCsrfTest < ActionDispatch::IntegrationTest
  setup do
    @designer = designers(:one)
    @model = Model3d.create!(designer: @designer, title: "CSRF Bracket", slug: "csrf-bracket",
      status: "draft")
    sign_in_as @designer

    # Only the publish leg runs under protection: signing in is not what we test.
    @forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @forgery_protection
  end

  test "the draft form's token is accepted by the review action it retargets to" do
    get edit_designer_model_path(@model)
    assert_response :success

    token = css_select("form.listing-editor-form input[name='authenticity_token']").first&.[]("value")
    assert token.present?, "the listing editor form must carry an authenticity token"

    post review_designer_model_path(@model),
      params: { authenticity_token: token, model3d: { title: @model.title } }

    assert_not_equal 422, response.status,
      "publishing is unreachable: the form token is rejected by the review action"
    # Reaching the action is the point, so pin that rather than only ruling out
    # the forgery status — a 500 must not read as success here. This bare draft
    # is not review-ready, so the action redirects back to the editor.
    assert_redirected_to edit_designer_model_path(@model)
  end
end
