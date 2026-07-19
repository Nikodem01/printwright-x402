require "test_helper"

class ModelVersionTest < ActiveSupport::TestCase
  setup do
    @model = Model3d.create!(
      designer: designers(:one), title: "Versioned clamp", slug: "versioned-clamp",
      status: "published", file_hash: "sha256:#{'a' * 64}"
    )
  end

  test "builds a compact immutable update event without changing the certified model hash" do
    original_hash = @model.file_hash
    version = @model.model_versions.create!(
      number: 2, file_kind: "stl", file_hash: "sha256:#{'b' * 64}",
      changelog: "Strengthened the hinge.",
      changelog_hash: "sha256:#{Digest::SHA256.hexdigest('Strengthened the hinge.')}",
      published_at: Time.utc(2026, 7, 19, 12)
    )

    event = version.anchor_payload
    assert_equal "pwv-1", event["schema"]
    assert_equal [ @model.id, 2, original_hash, version.file_hash, version.changelog_hash ],
      event.values_at("model_id", "version", "original_hash", "file_hash", "changelog_hash")
    assert_operator JSON.generate(event).bytesize, :<, 1024
    assert_equal original_hash, @model.reload.file_hash
  end

  test "version numbers and hashes are constrained" do
    version = @model.model_versions.new(number: 1, file_kind: "exe", file_hash: "nope",
      changelog: "", changelog_hash: "nope", published_at: Time.current)

    assert_not version.valid?
    assert_includes version.errors[:number], "must be greater than or equal to 2"
    assert version.errors[:file_hash].any?
    assert version.errors[:changelog].any?
  end
end
