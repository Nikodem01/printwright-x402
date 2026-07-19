require "test_helper"
require "open3"

class CatalogAssetsTest < ActiveSupport::TestCase
  test "seed assets pass provenance and printability checks" do
    output, status = Open3.capture2e(RbConfig.ruby, Rails.root.join("scripts/check_seed_assets.rb").to_s)

    assert_predicate status, :success?, output
    assert_includes output, "Seed assets valid: 12"
  end

  test "seed upgrade preserves a purchased legacy file and publishes a replacement" do
    old_bytes = "solid legacy\nendsolid legacy\n"
    legacy = Model3d.create!(
      designer: designers(:one), title: "Legacy stand", slug: "phone-stand",
      file_hash: "sha256:#{Digest::SHA256.hexdigest(old_bytes)}", status: "published"
    )
    file = legacy.model_files.create!(kind: "stl", position: 0)
    file.file.attach(io: StringIO.new(old_bytes), filename: "phone-stand.stl", content_type: "model/stl")
    offer = legacy.license_offers.create!(kind: "personal", price_cents: 100)
    purchase = offer.purchases.create!(replay_key: SecureRandom.hex(32))

    capture_io { load Rails.root.join("db/seeds.rb") }

    replacement = Model3d.find_by!(slug: "phone-stand")
    assert_not_equal legacy.id, replacement.id
    assert_predicate replacement, :published?
    assert_equal "sha256:#{Digest::SHA256.file(Rails.root.join("db/seed_assets/phone-stand.stl")).hexdigest}",
                 replacement.file_hash
    assert_predicate legacy.reload, :retired?
    assert_equal "phone-stand-legacy-#{legacy.id}", legacy.slug
    assert_equal old_bytes, legacy.model_files.find_by!(kind: "stl").file.download
    assert_equal legacy, purchase.reload.model3d

    seed_slugs = PROVENANCE.values.pluck("slug")
    seeded_models = Model3d.where(slug: seed_slugs).includes(model_files: { file_attachment: :blob })
    assert_equal 12, seeded_models.length
    seeded_models.each do |seeded_model|
      preview = seeded_model.preview_file
      assert_predicate preview.file, :attached?, "#{seeded_model.slug} has no preview"
      assert preview.file.download.start_with?(PreviewMeshes::Generator::HEADER)
      assert_not_includes seeded_model.printable_files, preview
    end
  end
end
