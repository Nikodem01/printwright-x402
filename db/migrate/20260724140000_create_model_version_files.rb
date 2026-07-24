class CreateModelVersionFiles < ActiveRecord::Migration[8.1]
  def up
    create_table :model_version_files do |t|
      t.references :model_version, null: false, foreign_key: true
      t.string :kind, null: false
      t.integer :position, null: false, default: 0
      t.string :file_hash, null: false
      t.timestamps
    end

    # Every version predating multi-file bundles becomes a one-file bundle
    # mirroring its single has_one_attached :file, reusing the existing blob
    # (never re-uploading it), so nothing about delivery changes for rows
    # created before this migration.
    ModelVersion.find_each do |version|
      next unless version.file.attached?

      version_file = version.version_files.create!(
        position: 0, kind: version.file_kind, file_hash: version.file_hash
      )
      version_file.file.attach(version.file.blob)
    end
  end

  def down
    drop_table :model_version_files
  end
end
