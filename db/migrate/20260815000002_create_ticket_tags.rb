class CreateTicketTags < ActiveRecord::Migration[8.1]
  def change
    create_table :ticket_tags do |t|
      t.references :ticket, null: false, foreign_key: true
      t.references :tag, null: false, foreign_key: true
      t.datetime :created_at, null: false
    end
    add_index :ticket_tags, [:ticket_id, :tag_id], unique: true
  end
end
