# frozen_string_literal: true

require "test_helper"

# The bearer token behind /mcp. What matters: the database never holds a
# usable token, issuing again rotates (the old one dies at once), and the
# allowlist is consulted on every use, not just when the token was made.
class McpTokenTest < ActiveSupport::TestCase
  OIDC = {
    "OIDC_CLIENT_ID" => "spool",
    "OIDC_CLIENT_SECRET" => "secret",
    "OIDC_DISCOVERY_URL" => "https://clinch.example.com"
  }.freeze

  setup do
    @agent = Agent.create!(oidc_sub: "agent-1", email: "sam@spool.test", name: "Sam")
  end

  test "issuing hands back the token once and stores only its digest" do
    plaintext = McpToken.issue!(@agent)

    assert_match(/\Aspool_[1-9A-HJ-NP-Za-km-z]{43}\z/, plaintext)
    token = @agent.reload.mcp_token
    assert_equal OpenSSL::Digest::SHA256.hexdigest(plaintext), token.token_digest
    assert_not token.attributes.values.any? { |value| value.to_s.include?(plaintext) },
      "no column holds the token itself"
  end

  test "a presented token authenticates as its agent" do
    plaintext = McpToken.issue!(@agent)

    assert_equal @agent, McpToken.authenticate(plaintext)&.agent
  end

  test "issuing again rotates: the old token stops working at once" do
    old = McpToken.issue!(@agent)
    new = McpToken.issue!(@agent)

    assert_nil McpToken.authenticate(old)
    assert_equal @agent, McpToken.authenticate(new)&.agent
    assert_equal 1, McpToken.where(agent: @agent).count
  end

  test "an unknown, blank or revoked token is nobody" do
    plaintext = McpToken.issue!(@agent)

    assert_nil McpToken.authenticate("spool_#{"x" * 43}")
    assert_nil McpToken.authenticate("")
    assert_nil McpToken.authenticate(nil)

    @agent.mcp_token.destroy!
    assert_nil McpToken.authenticate(plaintext)
  end

  # The allowlist is the whole of Spool's access control, so taking someone off
  # it has to take their token with it — on the next call, not at some expiry.
  test "an agent taken off the allowlist loses the token with it" do
    plaintext = McpToken.issue!(@agent)

    with_env(OIDC.merge("SPOOL_ALLOWED_USERS" => "sam@spool.test")) do
      assert_equal @agent, McpToken.authenticate(plaintext)&.agent
    end

    with_env(OIDC.merge("SPOOL_ALLOWED_USERS" => "someone-else@spool.test")) do
      assert_nil McpToken.authenticate(plaintext)
    end
  end

  test "use is recorded, but not rewritten on every call" do
    plaintext = McpToken.issue!(@agent)
    token = @agent.reload.mcp_token
    assert_nil token.last_used_at

    McpToken.authenticate(plaintext)
    first = token.reload.last_used_at
    assert_not_nil first

    travel 1.minute do
      McpToken.authenticate(plaintext)
      assert_equal first, token.reload.last_used_at
    end

    travel 10.minutes do
      McpToken.authenticate(plaintext)
      assert_operator token.reload.last_used_at, :>, first
    end
  end

  test "an agent's token goes when the agent does" do
    McpToken.issue!(@agent)

    assert_difference -> { McpToken.count }, -1 do
      @agent.destroy!
    end
  end
end
