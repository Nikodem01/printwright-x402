require "test_helper"

class Designer::ModelsUploadTest < ActionDispatch::IntegrationTest
  setup do
    @model = Model3d.create!(designer: designers(:one), title: "Draft widget", slug: "draft-upload-widget")
    sign_in_as designers(:one)
  end

  def upload(bytes, filename, type = "application/octet-stream")
    Rack::Test::UploadedFile.new(StringIO.new(bytes), type, original_filename: filename)
  end

  def submit(*files)
    patch designer_model_path(@model), params: {
      model3d: { title: @model.title, printable_files: files }
    }
  end

  test "a real STL still attaches" do
    submit(fixture_file_upload(Rails.root.join("db/seed_assets/calibration-cube.stl"), "model/stl"))

    assert_equal %w[stl], @model.reload.printable_files.map(&:kind)
  end

  # The kind used to be derived from the extension against every ModelFile kind,
  # so naming a file .preview walked past content checking entirely.
  test "a file named to claim an internal kind is refused, not stored unchecked" do
    submit(upload("MZ\x90\x00 arbitrary bytes", "evil.preview"))

    assert_empty @model.reload.model_files
    follow_redirect!
    assert_match(/evil\.preview/, response.body)
    assert_match(/STL, 3MF or STEP/, response.body)
  end

  test "an image cannot enter through the printable field" do
    submit(upload("\x89PNG\r\n\x1a\n".b + "x", "sneak.render"))

    assert_empty @model.reload.model_files
  end

  # An unknown format used to be checked as an STL, so an OBJ was reported as a
  # malformed STL. Say what was actually wrong.
  test "an unsupported format is named rather than reported as a broken STL" do
    submit(upload("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n", "model.obj"))

    assert_empty @model.reload.model_files
    follow_redirect!
    assert_match(/model\.obj/, response.body)
    assert_match(/STL, 3MF or STEP/, response.body)
    assert_no_match(/not an STL file/, response.body)
  end

  test "a zip is refused at the printable field" do
    submit(upload("PK\x03\x04 zip bytes", "bundle.zip"))

    assert_empty @model.reload.model_files
  end

  # A buyer told a listing includes several files should receive several files,
  # not one file under several names.
  test "the same bytes cannot be attached twice in one submission" do
    submit(
      fixture_file_upload(Rails.root.join("db/seed_assets/calibration-cube.stl"), "model/stl"),
      upload(Rails.root.join("db/seed_assets/calibration-cube.stl").binread, "cube-copy.stl")
    )

    assert_equal 1, @model.reload.printable_files.count
    follow_redirect!
    assert_match(/cube-copy\.stl/, response.body)
  end

  test "the same bytes cannot be added to a bundle that already has them" do
    submit(fixture_file_upload(Rails.root.join("db/seed_assets/calibration-cube.stl"), "model/stl"))
    assert_equal 1, @model.reload.printable_files.count

    submit(upload(Rails.root.join("db/seed_assets/calibration-cube.stl").binread, "cube-again.stl"))

    assert_equal 1, @model.reload.printable_files.count
    follow_redirect!
    assert_match(/cube-again\.stl/, response.body)
  end

  test "two genuinely different files both attach" do
    submit(
      fixture_file_upload(Rails.root.join("db/seed_assets/calibration-cube.stl"), "model/stl"),
      fixture_file_upload(Rails.root.join("db/seed_assets/cable-clip.stl"), "model/stl")
    )

    assert_equal 2, @model.reload.printable_files.count
  end

  test "a good file in the same submission survives a bad one" do
    submit(
      fixture_file_upload(Rails.root.join("db/seed_assets/calibration-cube.stl"), "model/stl"),
      upload("v 0 0 0", "model.obj")
    )

    assert_equal %w[stl], @model.reload.printable_files.map(&:kind)
    follow_redirect!
    assert_match(/model\.obj/, response.body)
  end
end
