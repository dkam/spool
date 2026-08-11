class CreateAgents < ActiveRecord::Migration[8.1]
  def change
    # Agents are created on first successful OIDC login, keyed by the provider's
    # `sub` claim. There is no password column, no registration and no reset
    # flow — see docs/auth.md. Email is stored too (it's what the allowlist
    # matches on and what the UI shows) but `sub` is the identity: an IdP can
    # change someone's email address, and the same person must remain the same
    # agent when it does.
    create_table :agents do |t|
      t.string :oidc_sub, null: false, index: {unique: true}
      t.string :email, null: false, index: {unique: true}
      t.string :name

      t.timestamps
    end
  end
end
