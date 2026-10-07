class CreateMcpTokens < ActiveRecord::Migration[8.1]
  def change
    # One bearer token per agent for /mcp. Only a SHA-256 digest is stored: the
    # token is shown once when issued, and a copy of the database (a backup,
    # a Litestream replica) holds nothing that can be presented. A digest
    # rather than bcrypt because the token is 256 random bits — there is no
    # dictionary to slow down, and the lookup has to be an indexed equality.
    create_table :mcp_tokens do |t|
      t.references :agent, null: false, foreign_key: true, index: {unique: true}
      t.string :token_digest, null: false
      t.datetime :last_used_at
      t.timestamps
    end

    add_index :mcp_tokens, :token_digest, unique: true
  end
end
