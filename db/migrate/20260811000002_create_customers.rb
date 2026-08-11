class CreateCustomers < ActiveRecord::Migration[8.1]
  def change
    # Customers never authenticate — there is no portal. A customer row is
    # created by the ingest pipeline the first time an address writes in, and
    # exists to hang tickets and free-text notes off.
    create_table :customers do |t|
      t.string :email, null: false, index: {unique: true}
      t.string :name
      t.text :notes

      t.timestamps
    end
  end
end
