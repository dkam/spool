# Issuing, rotating and revoking the signed-in agent's MCP token. Issuing and
# rotating are one act — McpToken.issue! replaces whatever was there.
class Settings::McpTokensController < ApplicationController
  # The token is shown exactly once. Only its digest is stored, so the redirect
  # carries it to the settings page in the flash: the session cookie is
  # encrypted, and the flash is gone after that one request. Rendering it from
  # this POST instead would leave a reload re-submitting — and rotating away
  # the token just copied.
  def create
    flash[:mcp_token] = McpToken.issue!(current_agent)
    redirect_to settings_path, status: :see_other
  end

  def destroy
    current_agent.mcp_token&.destroy!
    redirect_to settings_path, status: :see_other, notice: "Token revoked. Anything still using it is refused from now on."
  end
end
