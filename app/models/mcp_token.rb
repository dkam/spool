# frozen_string_literal: true

# An agent's bearer token for the MCP endpoint (POST /mcp, McpController).
# One per agent, issued and rotated from Settings. See docs/mcp.md.
#
# Shaped after splat's McpToken, with two differences:
#
# - **Only a digest is stored.** Splat keeps the token itself so its settings
#   page can show it again; here the token is shown once, when issued, and
#   rotated if it is lost. A token from this table can send mail to customers,
#   and the database is the file that gets backed up and replicated — so the
#   copy of it that ends up somewhere else should hold nothing presentable.
# - **It belongs to an Agent.** Splat has no users table and keys tokens by
#   email; Spool has agents, and a write over MCP needs one to sign it.
#
# Kept from splat: the allowlist is re-checked on every use, so taking someone
# off SPOOL_ALLOWED_USERS / SPOOL_ALLOWED_DOMAINS revokes their token on its
# next call, with no row to remember to delete.
class McpToken < ApplicationRecord
  # Recognisable in a config file or a leaked paste, and a pattern a secret
  # scanner can be taught. The rest is 43 base58 characters: ~250 bits.
  PREFIX = "spool_"

  # last_used_at is shown in Settings to answer "is anything still using this?"
  # — it isn't worth a write on every call from a chatty client.
  TOUCH_AFTER = 5.minutes

  belongs_to :agent

  validates :token_digest, presence: true, uniqueness: true
  validates :agent_id, uniqueness: true

  # Issues the agent a new token, replacing any they had — the old one stops
  # working at once. Returns the token itself, which is never stored and so
  # cannot be had again; the caller shows it to the agent and forgets it.
  def self.issue!(agent)
    plaintext = PREFIX + SecureRandom.base58(43)

    transaction do
      where(agent: agent).delete_all
      create!(agent: agent, token_digest: digest(plaintext))
    end

    plaintext
  end

  # The token for a presented bearer value, or nil. Unknown, revoked and
  # off-allowlist all come back nil: a caller that isn't let in is told nothing
  # about why.
  def self.authenticate(presented)
    return nil if presented.blank?

    token = includes(:agent).find_by(token_digest: digest(presented))
    return nil unless token&.agent_allowed?

    token.touch_last_used!
    token
  end

  def self.digest(plaintext)
    OpenSSL::Digest::SHA256.hexdigest(plaintext)
  end

  # Open mode has no allowlist to consult — and exists only in development and
  # test (production refuses to boot that way). Half-configured auth is refused
  # before this is reached; see McpController.
  def agent_allowed?
    !SpoolAuthorization.oidc_configured? || SpoolAuthorization.authorized?(agent.email)
  end

  def touch_last_used!
    return if last_used_at.present? && last_used_at > TOUCH_AFTER.ago

    # update_column: no validations and no updated_at churn on the read path.
    update_column(:last_used_at, Time.current)
  end
end
