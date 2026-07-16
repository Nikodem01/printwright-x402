# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_17_000004) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_trgm"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "designers", force: :cascade do |t|
    t.text "bio"
    t.datetime "created_at", null: false
    t.string "display_name", null: false
    t.string "email_address", null: false
    t.string "hedera_account_id"
    t.string "password_digest", null: false
    t.datetime "payout_account_verified_at"
    t.datetime "updated_at", null: false
    t.boolean "verified", default: false, null: false
    t.index ["email_address"], name: "index_designers_on_email_address", unique: true
  end

  create_table "download_grants", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "license_id", null: false
    t.integer "max_uses", default: 10, null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.integer "uses", default: 0, null: false
    t.index ["license_id"], name: "index_download_grants_on_license_id"
    t.index ["token"], name: "index_download_grants_on_token", unique: true
  end

  create_table "ledger_entries", force: :cascade do |t|
    t.bigint "amount_base_units", null: false
    t.string "asset", null: false
    t.datetime "created_at", null: false
    t.bigint "designer_id"
    t.string "entry_kind", null: false
    t.string "held_by", default: "treasury", null: false
    t.bigint "purchase_id", null: false
    t.string "tx_id"
    t.index ["designer_id"], name: "index_ledger_entries_on_designer_id"
    t.index ["purchase_id", "entry_kind"], name: "index_ledger_entries_on_purchase_id_and_entry_kind", unique: true
    t.index ["purchase_id"], name: "index_ledger_entries_on_purchase_id"
  end

  create_table "license_offers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "currency", default: "USDC", null: false
    t.string "kind", null: false
    t.integer "max_units"
    t.bigint "model3d_id", null: false
    t.integer "price_cents", null: false
    t.string "terms_hash"
    t.text "terms_md"
    t.datetime "updated_at", null: false
    t.index ["model3d_id"], name: "index_license_offers_on_model3d_id"
  end

  create_table "licenses", force: :cascade do |t|
    t.string "cert_id"
    t.jsonb "cert_json", default: {}, null: false
    t.datetime "created_at", null: false
    t.bigint "hcs_sequence_number"
    t.string "hcs_topic_id"
    t.bigint "purchase_id", null: false
    t.integer "serial", null: false
    t.datetime "updated_at", null: false
    t.string "verify_slug"
    t.index ["cert_id"], name: "index_licenses_on_cert_id", unique: true
    t.index ["purchase_id"], name: "index_licenses_on_purchase_id", unique: true
    t.index ["verify_slug"], name: "index_licenses_on_verify_slug", unique: true
  end

  create_table "model_files", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "kind", null: false
    t.bigint "model3d_id", null: false
    t.integer "position", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["model3d_id"], name: "index_model_files_on_model3d_id"
  end

  create_table "models3d", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.bigint "designer_id", null: false
    t.string "file_hash"
    t.jsonb "printability", default: {}, null: false
    t.string "slug", null: false
    t.string "status", default: "draft", null: false
    t.string "tags", default: [], null: false, array: true
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["designer_id"], name: "index_models3d_on_designer_id"
    t.index ["slug"], name: "index_models3d_on_slug", unique: true
    t.index ["status"], name: "index_models3d_on_status"
    t.index ["tags"], name: "index_models3d_on_tags", using: :gin
    t.index ["title"], name: "index_models3d_on_title_trgm", opclass: :gin_trgm_ops, using: :gin
  end

  create_table "purchases", force: :cascade do |t|
    t.string "amount_base_units"
    t.string "asset"
    t.string "buyer_hint"
    t.datetime "created_at", null: false
    t.string "error_reason"
    t.bigint "license_offer_id", null: false
    t.string "payment_tx_id"
    t.string "refund_tx_id"
    t.string "replay_key", null: false
    t.jsonb "requirements_json", default: {}, null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["license_offer_id"], name: "index_purchases_on_license_offer_id"
    t.index ["payment_tx_id"], name: "index_purchases_on_payment_tx_id", unique: true, where: "(payment_tx_id IS NOT NULL)"
    t.index ["replay_key"], name: "index_purchases_on_replay_key", unique: true
    t.index ["status"], name: "index_purchases_on_status"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "designer_id", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.index ["designer_id"], name: "index_sessions_on_designer_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "download_grants", "licenses"
  add_foreign_key "ledger_entries", "designers"
  add_foreign_key "ledger_entries", "purchases"
  add_foreign_key "license_offers", "models3d"
  add_foreign_key "licenses", "purchases"
  add_foreign_key "model_files", "models3d"
  add_foreign_key "models3d", "designers"
  add_foreign_key "purchases", "license_offers"
  add_foreign_key "sessions", "designers"
end
