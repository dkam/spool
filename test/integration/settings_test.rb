# frozen_string_literal: true

require "test_helper"

# The settings screen, which for now is the MCP token: make one, see it once,
# rotate it, revoke it. Runs in open mode, as the stand-in development agent.
class SettingsTest < ActionDispatch::IntegrationTest
  setup do
    # Created up front for the same reason as in UiFlowsTest: the lazy
    # provisioning write would land on a GET.
    @agent = Agent.find_or_create_by!(oidc_sub: "dev-open-mode") do |a|
      a.email = ENV.fetch("SPOOL_DEV_AGENT_EMAIL", "dev@localhost")
      a.name = "Development Agent"
    end
  end

  def shown_token
    css_select("[data-mcp-token]").first&.text&.strip
  end

  test "the header links to settings" do
    get root_path
    follow_redirect!

    assert_select "header a[href=?]", settings_path, text: "Settings"
  end

  test "with no token, settings offers to make one and says where the endpoint is" do
    get settings_path

    assert_response :success
    assert_select "h1", "Settings"
    assert_match mcp_url, response.body
    assert_select "form[action=?] button", settings_mcp_token_path, text: /Generate token/
    assert_nil shown_token
  end

  test "a new token is shown once, with the command that uses it" do
    post settings_mcp_token_path
    assert_redirected_to settings_path
    follow_redirect!

    token = shown_token
    assert_match(/\Aspool_/, token)
    assert_equal @agent, McpToken.authenticate(token)&.agent
    assert_select "[data-mcp-command]", text: /claude mcp add --transport http .*#{Regexp.escape(mcp_url)}.*Bearer #{token}/m

    # Turbo would otherwise keep a snapshot of this page, token and all, and
    # show it again on Back.
    assert_select "meta[name=turbo-cache-control][content=no-cache]"

    get settings_path
    assert_nil shown_token, "the token is not shown a second time"
    assert_select "form[action=?] button", settings_mcp_token_path, text: /Rotate/
  end

  test "rotating replaces the token and the old one stops working" do
    old = McpToken.issue!(@agent)

    post settings_mcp_token_path
    follow_redirect!

    assert_nil McpToken.authenticate(old)
    assert_equal @agent, McpToken.authenticate(shown_token)&.agent
  end

  test "revoking leaves no token" do
    old = McpToken.issue!(@agent)

    delete settings_mcp_token_path
    assert_redirected_to settings_path
    follow_redirect!

    assert_nil McpToken.authenticate(old)
    assert_nil @agent.reload.mcp_token
    assert_select "form[action=?] button", settings_mcp_token_path, text: /Generate token/
  end

  test "settings says when the token was last used" do
    plaintext = McpToken.issue!(@agent)
    McpToken.authenticate(plaintext)

    get settings_path

    assert_select "[data-mcp-last-used]", text: "just now"
  end
end
