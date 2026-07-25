require "test_helper"

class Uploads::BundleTest < ActiveSupport::TestCase
  def file(kind, filename, digest = nil)
    { kind: kind, filename: filename, digest: digest || "sha256:#{Digest::SHA256.hexdigest(filename)}" }
  end

  test "a bundle needs a file we can actually geometry-check" do
    reason = Uploads::Bundle.missing_analyzable_reason([ file("step", "part.step") ])

    assert_match(/STL or 3MF/, reason)
    assert_match(/part\.step/, reason)
  end

  test "a CAD companion is accepted alongside a printable file" do
    assert_nil Uploads::Bundle.missing_analyzable_reason(
      [ file("stl", "part.stl"), file("step", "part.step") ]
    )
  end

  test "renders alone are not a printable bundle" do
    assert_match(/STL or 3MF/, Uploads::Bundle.missing_analyzable_reason([ file("render", "shot.png") ]))
  end

  test "an empty bundle has nothing to say about analyzability" do
    assert_nil Uploads::Bundle.missing_analyzable_reason([])
  end

  test "3MF counts as analyzable" do
    assert_nil Uploads::Bundle.missing_analyzable_reason([ file("3mf", "part.3mf") ])
  end

  test "the same bytes under two names is refused, naming both files" do
    reason = Uploads::Bundle.duplicate_reason(
      [ file("stl", "cube.stl", "sha256:abc"), file("stl", "cube-copy.stl", "sha256:abc") ]
    )

    assert_match(/cube-copy\.stl/, reason)
    assert_match(/cube\.stl/, reason)
  end

  test "distinct files are fine" do
    assert_nil Uploads::Bundle.duplicate_reason(
      [ file("stl", "a.stl", "sha256:aaa"), file("stl", "b.stl", "sha256:bbb") ]
    )
  end

  test "a duplicate is found among unrelated files" do
    reason = Uploads::Bundle.duplicate_reason([
      file("stl", "a.stl", "sha256:aaa"),
      file("render", "shot.png", "sha256:ccc"),
      file("stl", "a-again.stl", "sha256:aaa")
    ])

    assert_match(/a-again\.stl/, reason)
  end

  test "the same file in different formats is not a duplicate" do
    assert_nil Uploads::Bundle.duplicate_reason(
      [ file("stl", "part.stl", "sha256:aaa"), file("step", "part.step", "sha256:bbb") ]
    )
  end
end
