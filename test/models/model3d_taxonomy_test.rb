require "test_helper"

class Model3dTaxonomyTest < ActiveSupport::TestCase
  test "published catalog taxonomy is constrained to public keys" do
    model = Model3d.new(
      designer: designers(:one), title: "Taxonomy", slug: "taxonomy", status: "published",
      category: "made-up", collections: %w[small-space made-up]
    )

    assert_not model.valid?
    assert_includes model.errors[:category], "is not included in the list"
    assert_includes model.errors[:collections], "contains an unknown collection"
  end

  test "taxonomy labels and descriptions are stable public copy" do
    assert_equal "Desk organization", Model3d.category_definition("desk-organization").fetch(:name)
    assert_equal "Small-space wins", Model3d.collection_definition("small-space").fetch(:name)
    assert_raises(ActiveRecord::RecordNotFound) { Model3d.category_definition("unknown") }
    assert_raises(ActiveRecord::RecordNotFound) { Model3d.collection_definition("unknown") }
  end
end
