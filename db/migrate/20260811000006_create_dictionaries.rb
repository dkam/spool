class CreateDictionaries < ActiveRecord::Migration[8.1]
  def change
    # zstd dictionaries live in the same file as the rows they compress, so any
    # restored backup is self-describing. Never mutate one in place: train a new
    # version and leave existing rows pointing at the old one, which stays
    # readable forever.
    #
    # Ships empty. Messages compress with plain zstd (nil dictionary id) until
    # the corpus is large enough to train against — see docs/compression.md.
    create_table :dictionaries do |t|
      t.string :kind, null: false          # headers | body
      t.integer :version, null: false
      t.binary :data, null: false
      t.integer :sample_count

      t.timestamps
    end

    add_index :dictionaries, [:kind, :version], unique: true
  end
end
