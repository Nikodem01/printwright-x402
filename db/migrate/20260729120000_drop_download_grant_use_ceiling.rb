class DropDownloadGrantUseCeiling < ActiveRecord::Migration[8.1]
  # `max_uses` rationed downloads of a file the buyer had already paid for and
  # could copy freely. It stopped nothing — the receipt capability re-mints a
  # grant on demand — while giving a multi-file download a way to run out
  # halfway through. Request cost is bounded by the files endpoint's rate limit
  # instead. `uses` stays: designer analytics counts licenses that were actually
  # downloaded.
  def change
    remove_column :download_grants, :max_uses, :integer, default: 10, null: false
  end
end
