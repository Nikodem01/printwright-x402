class AddNftFields < ActiveRecord::Migration[8.0]
  def change
    add_column :designers, :nft_collection_id, :string
    add_column :licenses, :nft_token_id, :string
    add_column :licenses, :nft_serial, :integer
    add_column :licenses, :nft_claim_state, :string # none until minted: pending | claimed
    add_column :licenses, :nft_airdrop_tx_id, :string
  end
end
