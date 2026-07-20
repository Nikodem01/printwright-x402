require "test_helper"

class AutoRenders::GeneratorTest < ActiveSupport::TestCase
  test "renders twelve named 800 by 600 PNG turntable frames without a shell" do
    frames = AutoRenders::Generator.call(
      bytes: Rails.root.join("db/seed_assets/calibration-cube.stl").binread,
      executable: Rails.root.join("test/fixtures/files/fake_openscad").to_s
    )

    assert_equal 12.times.map { |index| format("angle-%03d", index * 30) }, frames.map(&:name)
    frames.each do |frame|
      assert frame.bytes.start_with?(AutoRenders::Generator::PNG_SIGNATURE)
      assert_equal [ 800, 600 ], frame.bytes.byteslice(16, 8).unpack("NN")
    end
  end

  test "raises a bounded renderer error" do
    error = assert_raises(AutoRenders::Generator::Error) do
      AutoRenders::Generator.call(bytes: "solid empty\nendsolid empty", executable: "/bin/false")
    end

    assert_includes error.message, "OpenSCAD thumbnail failed"
  end
end
