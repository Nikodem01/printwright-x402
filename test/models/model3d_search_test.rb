require "test_helper"

class Model3dSearchTest < ActiveSupport::TestCase
  setup do
    @beaver = Model3d.create!(
      designer: designers(:one), title: "Articulated Beaver with Hat", slug: "b-#{SecureRandom.hex(3)}",
      tags: %w[beaver hat], status: "published"
    )
    Model3d.create!(designer: designers(:one), title: "Calibration Cube", slug: "c-#{SecureRandom.hex(3)}",
                    tags: %w[calibration], status: "published")
  end

  test "misspelled query falls back to trigram similarity and finds the beaver" do
    assert_equal [ @beaver.id ], Model3d.search("beavr").pluck(:id)
    assert_equal [ @beaver.id ], Model3d.search("beever hat").pluck(:id)
  end

  test "exact matches still win and rank before fuzzy kicks in" do
    assert_equal @beaver.id, Model3d.search("beaver").first.id
  end

  test "garbage finds nothing" do
    assert_empty Model3d.search("zxqvw")
    assert_empty Model3d.search("")
  end
end
