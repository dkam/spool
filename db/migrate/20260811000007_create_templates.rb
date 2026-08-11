class CreateTemplates < ActiveRecord::Migration[8.1]
  def change
    # Canned replies. Interpolated into the compose box for the agent to edit;
    # never auto-sent. Flat list, no categories.
    create_table :templates do |t|
      t.string :name, null: false
      t.string :subject
      t.text :body

      t.timestamps
    end
  end
end
