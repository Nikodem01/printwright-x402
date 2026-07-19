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

ActiveRecord::Schema[8.1].define(version: 2026_07_19_203000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_trgm"
  enable_extension "vector"

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

  create_table "admin_audit_logs", force: :cascade do |t|
    t.string "action", null: false
    t.bigint "actor_designer_id"
    t.datetime "created_at", null: false
    t.jsonb "details", default: {}, null: false
    t.string "ip_address"
    t.string "request_id"
    t.bigint "subject_id"
    t.string "subject_type"
    t.index ["actor_designer_id"], name: "index_admin_audit_logs_on_actor_designer_id"
    t.index ["created_at"], name: "index_admin_audit_logs_on_created_at"
    t.index ["subject_type", "subject_id"], name: "index_admin_audit_logs_on_subject_type_and_subject_id"
  end

  create_table "catalog_imports", force: :cascade do |t|
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.bigint "designer_id", null: false
    t.string "manifest_digest", null: false
    t.integer "model_count", default: 0, null: false
    t.jsonb "model_snapshots", default: {}, null: false
    t.datetime "rolled_back_at"
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["designer_id", "created_at"], name: "index_catalog_imports_on_designer_id_and_created_at"
    t.index ["designer_id"], name: "index_catalog_imports_on_designer_id"
  end

  create_table "chat_conversations", force: :cascade do |t|
    t.integer "approved_spend_cents", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.integer "lock_version", default: 0, null: false
    t.jsonb "purchase_proposal", default: {}, null: false
    t.jsonb "turns", default: [], null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_chat_conversations_on_expires_at"
  end

  create_table "designers", force: :cascade do |t|
    t.boolean "admin", default: false, null: false
    t.text "bio"
    t.datetime "created_at", null: false
    t.string "display_name", null: false
    t.string "email_address", null: false
    t.string "hedera_account_id"
    t.datetime "identity_verified_at"
    t.string "nft_collection_id"
    t.string "password_digest", null: false
    t.datetime "payout_account_verified_at"
    t.datetime "updated_at", null: false
    t.boolean "verified", default: false, null: false
    t.string "verified_profile_url"
    t.index ["admin"], name: "index_designers_on_admin"
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
    t.string "terms_version", default: "v1"
    t.datetime "updated_at", null: false
    t.index ["model3d_id"], name: "index_license_offers_on_model3d_id"
  end

  create_table "licenses", force: :cascade do |t|
    t.string "cert_id"
    t.jsonb "cert_json", default: {}, null: false
    t.datetime "created_at", null: false
    t.bigint "hcs_sequence_number"
    t.string "hcs_topic_id"
    t.string "nft_airdrop_tx_id"
    t.string "nft_claim_state"
    t.integer "nft_serial"
    t.string "nft_token_id"
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
    t.bigint "catalog_import_id"
    t.string "category"
    t.string "collections", default: [], null: false, array: true
    t.datetime "created_at", null: false
    t.text "description"
    t.bigint "designer_id", null: false
    t.vector "embedding", limit: 768
    t.string "embedding_text_digest"
    t.string "file_hash"
    t.string "geometry_hash"
    t.jsonb "mesh_analysis", default: {}, null: false
    t.string "mesh_analysis_digest"
    t.string "mesh_analysis_status", default: "pending", null: false
    t.jsonb "printability", default: {}, null: false
    t.string "slug", null: false
    t.string "status", default: "draft", null: false
    t.string "tags", default: [], null: false, array: true
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.datetime "warranty_accepted_at"
    t.index ["catalog_import_id"], name: "index_models3d_on_catalog_import_id"
    t.index ["category"], name: "index_models3d_on_category"
    t.index ["collections"], name: "index_models3d_on_collections", using: :gin
    t.index ["designer_id"], name: "index_models3d_on_designer_id"
    t.index ["embedding"], name: "index_models3d_on_embedding", opclass: :vector_cosine_ops, using: :hnsw
    t.index ["geometry_hash"], name: "index_models3d_on_geometry_hash"
    t.index ["mesh_analysis_status"], name: "index_models3d_on_mesh_analysis_status"
    t.index ["slug"], name: "index_models3d_on_slug", unique: true
    t.index ["status"], name: "index_models3d_on_status"
    t.index ["tags"], name: "index_models3d_on_tags", using: :gin
    t.index ["title"], name: "index_models3d_on_title_trgm", opclass: :gin_trgm_ops, using: :gin
  end

  create_table "profile_verifications", force: :cascade do |t|
    t.text "challenge_token", null: false
    t.datetime "created_at", null: false
    t.bigint "designer_id", null: false
    t.datetime "expires_at", null: false
    t.string "host", null: false
    t.text "last_error"
    t.string "profile_url", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.datetime "verified_at"
    t.index ["designer_id", "status"], name: "index_profile_verifications_on_designer_id_and_status"
    t.index ["designer_id"], name: "index_profile_verifications_on_designer_id"
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
    t.boolean "sandbox", default: false, null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["license_offer_id"], name: "index_purchases_on_license_offer_id"
    t.index ["payment_tx_id"], name: "index_purchases_on_payment_tx_id", unique: true, where: "(payment_tx_id IS NOT NULL)"
    t.index ["replay_key"], name: "index_purchases_on_replay_key", unique: true
    t.index ["sandbox"], name: "index_purchases_on_sandbox"
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
  add_foreign_key "admin_audit_logs", "designers", column: "actor_designer_id", on_delete: :nullify
  add_foreign_key "catalog_imports", "designers"
  add_foreign_key "download_grants", "licenses"
  add_foreign_key "ledger_entries", "designers"
  add_foreign_key "ledger_entries", "purchases"
  add_foreign_key "license_offers", "models3d"
  add_foreign_key "licenses", "purchases"
  add_foreign_key "model_files", "models3d"
  add_foreign_key "models3d", "catalog_imports"
  add_foreign_key "models3d", "designers"
  add_foreign_key "profile_verifications", "designers"
  add_foreign_key "purchases", "license_offers"
  add_foreign_key "sessions", "designers"
end
