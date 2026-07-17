require "test_helper"

class Uploads::ValidatorTest < ActiveSupport::TestCase
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
    assert_nil Uploads::Validator.reason_to_reject(upload_for("\x89PNG\r\n\x1a\n".b + "x", name: "r.png"), kind: "render")
    assert_nil Uploads::Validator.reason_to_reject(upload_for("\xFF\xD8\xFF".b + "x", name: "r.jpg"), kind: "render")
    assert_match(/PNG or JPEG/, Uploads::Validator.reason_to_reject(upload_for("GIF89a", name: "r.gif"), kind: "render"))

    assert_nil Uploads::Validator.reason_to_reject(upload_for("ISO-10303-21;\nHEADER;", name: "p.step"), kind: "step")
    assert_match(/not a STEP/, Uploads::Validator.reason_to_reject(upload_for("hello", name: "p.step"), kind: "step"))

    assert_match(/empty/, Uploads::Validator.reason_to_reject(upload_for("", name: "e.stl"), kind: "stl"))
  end
end
