require "test_helper"
require_relative "../../test_helpers/image_test_helper"

class Uploads::ValidatorTest < ActiveSupport::TestCase
  include ImageTestHelper

  def upload_for(bytes, name: "f.bin")
    Rack::Test::UploadedFile.new(StringIO.new(bytes), "application/octet-stream", original_filename: name)
  end

  test "ascii and structurally-valid binary STL pass; disguised PNG fails" do
    assert_nil Uploads::Validator.reason_to_reject(upload_for("solid cube\nendsolid cube\n", name: "c.stl"), kind: "stl")

    binary = ("\x00" * 80) + [ 2 ].pack("V") + ("\x00" * 100) # 84 + 2*50
    assert_nil Uploads::Validator.reason_to_reject(upload_for(binary, name: "b.stl"), kind: "stl")

    png_pretending = "\x89PNG\r\n\x1a\n".b + ("\x00" * 200)
    assert_match(/not a valid STL/, Uploads::Validator.reason_to_reject(upload_for(png_pretending, name: "evil.stl"), kind: "stl"))

    truncated = ("\x00" * 80) + [ 100 ].pack("V") + ("\x00" * 10)
    assert_match(/size mismatch/, Uploads::Validator.reason_to_reject(upload_for(truncated, name: "t.stl"), kind: "stl"))
  end

  test "3mf must be a real zip and expansion is bounded" do
    assert_match(/not a 3MF/, Uploads::Validator.reason_to_reject(upload_for("plain text", name: "x.3mf"), kind: "3mf"))

    zip_bytes = Zip::OutputStream.write_buffer do |z|
      z.put_next_entry("3D/model.model")
      z.write("<model/>")
    end.string
    assert_nil Uploads::Validator.reason_to_reject(upload_for(zip_bytes, name: "ok.3mf"), kind: "3mf")

    # zip-bomb-shaped: a highly compressible huge entry must be rejected by
    # its DECLARED uncompressed size, without extracting it
    bomb = Zip::OutputStream.write_buffer do |z|
      z.put_next_entry("boom.bin")
      z.write("\x00" * 5.megabytes) # small compressed, big declared
    end.string
    was = Uploads::Validator.max_3mf_uncompressed
    Uploads::Validator.max_3mf_uncompressed = 1.megabyte
    assert_match(/expands too large/, Uploads::Validator.reason_to_reject(upload_for(bomb, name: "bomb.3mf"), kind: "3mf"))
  ensure
    Uploads::Validator.max_3mf_uncompressed = was
  end

  test "renders accept png/jpeg only; step needs its header; size and empty caps hold" do
    assert_nil Uploads::Validator.reason_to_reject(upload_for(png_bytes, name: "r.png"), kind: "render")
    assert_nil Uploads::Validator.reason_to_reject(upload_for(jpeg_bytes, name: "r.jpg"), kind: "render")
    assert_match(/PNG or JPEG/, Uploads::Validator.reason_to_reject(upload_for("GIF89a", name: "r.gif"), kind: "render"))

    assert_nil Uploads::Validator.reason_to_reject(upload_for("ISO-10303-21;\nHEADER;", name: "p.step"), kind: "step")
    assert_match(/not a STEP/, Uploads::Validator.reason_to_reject(upload_for("hello", name: "p.step"), kind: "step"))

    assert_match(/empty/, Uploads::Validator.reason_to_reject(upload_for("", name: "e.stl"), kind: "stl"))
  end

  # The buyer decides from this image, so it has to be big enough to look at.
  # Magic bytes alone let a 1x1 pixel through as a product preview.
  test "a render too small to show a buyer anything is refused" do
    reason = Uploads::Validator.reason_to_reject(upload_for(png_bytes(width: 1, height: 1), name: "tiny.png"), kind: "render")

    assert_match(/1×1/, reason)
    assert_match(/640×480/, reason)
  end

  test "an image with one small side is refused" do
    reason = Uploads::Validator.reason_to_reject(upload_for(png_bytes(width: 1200, height: 200), name: "strip.png"), kind: "render")

    assert_match(/1200×200/, reason)
  end

  test "an absurdly large image is refused before it reaches a catalog card" do
    reason = Uploads::Validator.reason_to_reject(upload_for(png_bytes(width: 20_000, height: 20_000), name: "huge.png"), kind: "render")

    assert_match(/20000×20000/, reason)
  end

  test "jpeg dimensions are read past an EXIF block" do
    bytes = jpeg_bytes(width: 1920, height: 1080, exif_padding: 4_000)

    assert_nil Uploads::Validator.reason_to_reject(upload_for(bytes, name: "photo.jpg"), kind: "render")
  end

  test "a small jpeg behind EXIF is still caught" do
    bytes = jpeg_bytes(width: 32, height: 32, exif_padding: 4_000)

    assert_match(/32×32/, Uploads::Validator.reason_to_reject(upload_for(bytes, name: "small.jpg"), kind: "render"))
  end

  test "an image whose header cannot be read is refused rather than assumed fine" do
    reason = Uploads::Validator.reason_to_reject(upload_for("\x89PNG\r\n\x1a\n".b + "junk", name: "broken.png"), kind: "render")

    assert_match(/broken\.png/, reason)
  end

  test "an over-weight image is refused on its own terms" do
    was = Uploads::Validator.max_render_bytes
    Uploads::Validator.max_render_bytes = 1.kilobyte
    reason = Uploads::Validator.reason_to_reject(
      upload_for(png_bytes(padding: 4.kilobytes), name: "heavy.png"), kind: "render"
    )

    assert_match(/heavy\.png/, reason)
    assert_match(/larger than/, reason)
  ensure
    Uploads::Validator.max_render_bytes = was
  end

  # A kind with no branch used to fall out of the case statement as nil, which
  # reads as "acceptable". Anything unrecognised is refused instead.
  test "an unrecognised kind is refused rather than silently accepted" do
    reason = Uploads::Validator.reason_to_reject(upload_for("anything", name: "x.preview"), kind: "preview")

    assert_match(/x\.preview/, reason)
  end
end
