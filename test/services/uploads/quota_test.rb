require "test_helper"

# The disk is shared with the rest of the host, so these caps are the thing
# standing between an open signup form and a full filesystem. They are asserted
# at the boundary that actually protects it — bytes, not filenames — and the
# rejection has to be clean: a reason a designer can act on, never an exception.
class Uploads::QuotaTest < ActiveSupport::TestCase
  setup do
    @designer = designers(:one)
    @model = @designer.models3d.create!(
      title: "Quota Fixture", slug: "quota-fixture",
      file_hash: "sha256:#{Digest::SHA256.hexdigest('quota')}"
    )
  end

  teardown { restore_printwright }

  def attach_bytes(count)
    file = @model.model_files.create!(kind: "stl", position: @model.model_files.count)
    file.file.attach(io: StringIO.new("x" * count), filename: "f#{SecureRandom.hex(4)}.stl",
                     content_type: "model/stl")
    file
  end

  test "an upload that fits is accepted" do
    assert_nil Uploads::Quota.reason_to_reject(model: @model, upload_bytes: 1.kilobyte)
  end

  test "a designer over their byte allowance is refused with a reason they can act on" do
    set_printwright(storage_bytes_per_designer: 10.kilobytes, storage_bytes_global: 1.gigabyte)
    attach_bytes(9.kilobytes)

    reason = Uploads::Quota.reason_to_reject(model: @model, upload_bytes: 2.kilobytes)

    assert_match(/storage allowance/i, reason)
    assert_match(/delete a file/i, reason, "the message must tell the designer what to do")
  end

  test "the allowance counts bytes already stored, so a batch cannot walk past it" do
    set_printwright(storage_bytes_per_designer: 10.kilobytes, storage_bytes_global: 1.gigabyte)

    assert_nil Uploads::Quota.reason_to_reject(model: @model, upload_bytes: 6.kilobytes)
    attach_bytes(6.kilobytes)
    assert_not_nil Uploads::Quota.reason_to_reject(model: @model, upload_bytes: 6.kilobytes),
      "the second upload must be measured against the first"
  end

  test "one designer's usage does not consume another's allowance" do
    set_printwright(storage_bytes_per_designer: 10.kilobytes, storage_bytes_global: 1.gigabyte)
    attach_bytes(9.kilobytes)

    other_model = designers(:two).models3d.create!(
      title: "Other", slug: "other-quota-model",
      file_hash: "sha256:#{Digest::SHA256.hexdigest('other')}"
    )

    assert_nil Uploads::Quota.reason_to_reject(model: other_model, upload_bytes: 5.kilobytes)
  end

  test "the global cap refuses uploads even when the designer is well under theirs" do
    set_printwright(storage_bytes_per_designer: 1.gigabyte, storage_bytes_global: 1.kilobyte)
    attach_bytes(2.kilobytes)

    reason = Uploads::Quota.reason_to_reject(model: @model, upload_bytes: 1)

    assert_match(/total storage limit/i, reason)
  end

  test "a designer over their own quota is told that, not that the deployment is full" do
    set_printwright(storage_bytes_per_designer: 1.kilobyte, storage_bytes_global: 1.kilobyte)
    attach_bytes(2.kilobytes)

    assert_match(/storage allowance/i,
      Uploads::Quota.reason_to_reject(model: @model, upload_bytes: 1))
  end

  test "files per model are capped" do
    set_printwright(max_files_per_model: 2, storage_bytes_per_designer: 1.gigabyte,
                    storage_bytes_global: 1.gigabyte)
    2.times { attach_bytes(10) }

    assert_match(/maximum of 2 files/i,
      Uploads::Quota.reason_to_reject(model: @model, upload_bytes: 1))
  end

  test "models per designer are capped, and the message says how to recover" do
    set_printwright(max_models_per_designer: 1)

    reason = Uploads::Quota.reason_to_refuse_new_model(@designer)

    assert_match(/limit of 1 models/i, reason)
    assert_match(/delete a draft/i, reason)
  end

  test "a designer under the model cap is not refused" do
    set_printwright(max_models_per_designer: 50)

    assert_nil Uploads::Quota.reason_to_refuse_new_model(@designer)
  end

  # A mistyped cap must fail closed. Refusing every upload is loud, visible and
  # recoverable; reading a typo as "unlimited" fills the disk the host shares.
  test "a non-numeric cap becomes zero and refuses everything" do
    assert_equal 0, PrintwrightSettings.integer_or_zero("8GB")

    set_printwright(storage_bytes_global: 0)
    assert_match(/total storage limit/i,
      Uploads::Quota.reason_to_reject(model: @model, upload_bytes: 1))
  end
end
