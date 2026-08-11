class CreateOidcSessions < ActiveRecord::Migration[8.1]
  def change
    # Maps the IdP's session id (the `sid` claim) to a Spool session, so a
    # backchannel logout from the provider can terminate the right one. See
    # docs/auth.md.
    create_table :oidc_sessions do |t|
      t.string :oidc_sid, null: false, index: {unique: true}
      t.string :session_id, null: false
      t.string :user_email, null: false, index: true
      t.datetime :expires_at, null: false, index: true

      t.timestamps
    end
  end
end
