class RemovePreviewModelFiles < ActiveRecord::Migration[8.1]
  # The decimated "preview" mesh existed to feed a three.js viewer on the model
  # page. That viewer was replaced by the rendered turntable, which deliberately
  # never exposes the mesh, so these rows have had no reader since — and their
  # `kind` is no longer in ModelFile::KINDS, which would fail validation on any
  # future save. Purge the blobs, then drop the rows.
  #
  # Works on the storage and rows directly rather than through ModelFile, so it
  # does not depend on the model's callbacks or validations as they stand today.
  def up
    preview_ids = ModelFile.where(kind: "preview").pluck(:id)
    return if preview_ids.empty?

    ActiveStorage::Attachment
      .where(record_type: "ModelFile", record_id: preview_ids, name: "file")
      .find_each(&:purge)

    ModelFile.where(id: preview_ids).delete_all
  end

  def down
    # The generator that produced these meshes was deleted with the viewer they
    # fed; there is nothing left to rebuild them from.
    raise ActiveRecord::IrreversibleMigration
  end
end
