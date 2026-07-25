class RemoveNftColumns < ActiveRecord::Migration[8.1]
  def change
    remove_column :designers, :nft_collection_id, :string
    remove_column :licenses, :nft_token_id, :string
    remove_column :licenses, :nft_serial, :integer
    remove_column :licenses, :nft_claim_state, :string
    remove_column :licenses, :nft_airdrop_tx_id, :string
  end
end
