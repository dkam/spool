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

ActiveRecord::Schema[8.1].define(version: 2026_08_15_000003) do
  create_table "agents", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "name"
    t.string "oidc_sub", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_agents_on_email", unique: true
    t.index ["oidc_sub"], name: "index_agents_on_oidc_sub", unique: true
  end

  create_table "attachments", force: :cascade do |t|
    t.integer "byte_size"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.binary "data"
    t.string "sha256", null: false
    t.datetime "updated_at", null: false
    t.index ["sha256"], name: "index_attachments_on_sha256", unique: true
  end

  create_table "customers", force: :cascade do |t|
    t.datetime "blocked_at"
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "name"
    t.text "notes"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_customers_on_email", unique: true
  end

  create_table "dictionaries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.binary "data", null: false
    t.string "kind", null: false
    t.integer "sample_count"
    t.datetime "updated_at", null: false
    t.integer "version", null: false
    t.index ["kind", "version"], name: "index_dictionaries_on_kind_and_version", unique: true
  end

  create_table "ingest_cursors", force: :cascade do |t|
    t.text "position", null: false
    t.string "source", null: false
    t.datetime "updated_at", null: false
    t.index ["source"], name: "index_ingest_cursors_on_source", unique: true
  end

  create_table "message_attachments", force: :cascade do |t|
    t.integer "attachment_id", null: false
    t.string "content_id"
    t.string "filename"
    t.integer "message_id", null: false
    t.index ["attachment_id"], name: "index_message_attachments_on_attachment_id"
    t.index ["message_id"], name: "index_message_attachments_on_message_id"
  end

  create_table "messages", force: :cascade do |t|
    t.integer "agent_id"
    t.binary "body_blob"
    t.integer "body_dictionary_id"
    t.text "body_excerpt"
    t.datetime "created_at", null: false
    t.string "direction", null: false
    t.string "from_email"
    t.string "from_name"
    t.binary "headers_blob"
    t.integer "headers_dictionary_id"
    t.string "in_reply_to"
    t.string "message_id", null: false
    t.integer "raw_size"
    t.text "references_header"
    t.datetime "sent_at"
    t.string "subject"
    t.integer "ticket_id", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id"], name: "index_messages_on_agent_id"
    t.index ["in_reply_to"], name: "index_messages_on_in_reply_to"
    t.index ["message_id"], name: "index_messages_on_message_id", unique: true
    t.index ["sent_at"], name: "index_messages_on_sent_at"
    t.index ["ticket_id"], name: "index_messages_on_ticket_id"
  end

  create_table "oidc_sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "oidc_sid", null: false
    t.string "session_id", null: false
    t.datetime "updated_at", null: false
    t.string "user_email", null: false
    t.index ["expires_at"], name: "index_oidc_sessions_on_expires_at"
    t.index ["oidc_sid"], name: "index_oidc_sessions_on_oidc_sid", unique: true
    t.index ["user_email"], name: "index_oidc_sessions_on_user_email"
  end

  create_table "tags", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_tags_on_name", unique: true
  end

  create_table "templates", force: :cascade do |t|
    t.text "body"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.string "subject"
    t.datetime "updated_at", null: false
  end

  create_table "ticket_reads", force: :cascade do |t|
    t.integer "agent_id", null: false
    t.datetime "last_read_at", null: false
    t.integer "ticket_id", null: false
    t.index ["agent_id", "ticket_id"], name: "index_ticket_reads_on_agent_id_and_ticket_id", unique: true
    t.index ["agent_id"], name: "index_ticket_reads_on_agent_id"
    t.index ["ticket_id"], name: "index_ticket_reads_on_ticket_id"
  end

  create_table "ticket_tags", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "tag_id", null: false
    t.integer "ticket_id", null: false
    t.index ["tag_id"], name: "index_ticket_tags_on_tag_id"
    t.index ["ticket_id", "tag_id"], name: "index_ticket_tags_on_ticket_id_and_tag_id", unique: true
    t.index ["ticket_id"], name: "index_ticket_tags_on_ticket_id"
  end

  create_table "tickets", force: :cascade do |t|
    t.integer "assignee_id"
    t.datetime "created_at", null: false
    t.integer "customer_id", null: false
    t.datetime "last_activity_at"
    t.string "state", default: "open", null: false
    t.string "subject"
    t.datetime "updated_at", null: false
    t.index ["assignee_id"], name: "index_tickets_on_assignee_id"
    t.index ["customer_id"], name: "index_tickets_on_customer_id"
    t.index ["last_activity_at"], name: "index_tickets_on_last_activity_at"
    t.index ["state", "last_activity_at"], name: "index_tickets_on_state_and_last_activity_at"
  end

  add_foreign_key "message_attachments", "attachments"
  add_foreign_key "message_attachments", "messages"
  add_foreign_key "messages", "agents"
  add_foreign_key "messages", "tickets"
  add_foreign_key "ticket_reads", "agents"
  add_foreign_key "ticket_reads", "tickets"
  add_foreign_key "ticket_tags", "tags"
  add_foreign_key "ticket_tags", "tickets"
  add_foreign_key "tickets", "agents", column: "assignee_id"
  add_foreign_key "tickets", "customers"
end
