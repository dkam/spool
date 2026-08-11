class CreateTickets < ActiveRecord::Migration[8.1]
  def change
    create_table :tickets do |t|
      t.references :customer, null: false, foreign_key: true
      t.references :assignee, foreign_key: {to_table: :agents}
      t.string :subject

      # open | pending | closed. Three is enough. Resist on_hold.
      t.string :state, null: false, default: "open"

      t.datetime :last_activity_at, index: true

      t.timestamps
    end

    # The ticket list's only sort is last_activity_at within a state filter,
    # and that list is every screen's starting point.
    add_index :tickets, [:state, :last_activity_at]
  end
end
