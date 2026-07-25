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

  test "the anchored event is the same size for one file as for fifty" do
    version = @model.model_versions.create!(
      number: 2, file_kind: "stl", file_hash: "sha256:#{'b' * 64}",
      changelog: "Assembly.", changelog_hash: "sha256:#{Digest::SHA256.hexdigest('Assembly.')}",
      published_at: Time.utc(2026, 7, 25, 12)
    )
    version.version_files.create!(position: 0, kind: "stl", file_hash: "sha256:#{'b' * 64}")
    one_file = version.reload.anchor_payload.to_json.bytesize

    49.times do |index|
      version.version_files.create!(position: index + 1, kind: "step",
        file_hash: "sha256:#{format('%064x', index)}")
    end
    fifty_files = version.reload.anchor_payload.to_json.bytesize

    # A designer's part count is theirs to choose; the record commits to the
    # list rather than carrying it, so the message does not grow with it — the
    # only difference is the extra digit in file_count.
    assert_in_delta one_file, fifty_files, 2
    assert_operator fifty_files, :<, 1024
    assert_equal 50, version.anchor_payload["file_count"]
  end

  test "files_hash covers the ordered list, so a swapped or reordered file shows" do
    version = @model.model_versions.create!(
      number: 2, file_kind: "stl", file_hash: "sha256:#{'b' * 64}",
      changelog: "Two parts.", changelog_hash: "sha256:#{Digest::SHA256.hexdigest('Two parts.')}",
      published_at: Time.utc(2026, 7, 25, 12)
    )
    version.version_files.create!(position: 0, kind: "stl", file_hash: "sha256:#{'b' * 64}")
    version.version_files.create!(position: 1, kind: "step", file_hash: "sha256:#{'c' * 64}")
    published = version.reload.files_hash

    # Recomputable by the holder from the list the API returns.
    assert_equal published,
      "sha256:#{Digest::SHA256.hexdigest(version.file_manifest.to_json_c14n)}"

    version.version_files.ordered.last.update!(file_hash: "sha256:#{'d' * 64}")
    assert_not_equal published, version.reload.files_hash

    version.version_files.ordered.last.update!(file_hash: "sha256:#{'c' * 64}")
    assert_equal published, version.reload.files_hash
    version.version_files.ordered.first.update!(position: 5)
    assert_not_equal published, version.reload.files_hash
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
