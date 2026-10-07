# Settings for the signed-in agent. For now that is one thing, the MCP token;
# see docs/mcp.md.
class SettingsController < ApplicationController
  def show
    @mcp_token = current_agent.mcp_token

    # Present only on the request straight after issuing — see
    # Settings::McpTokensController#create. The page that shows it is never
    # cached, so Back can't bring it back either.
    @issued_token = flash[:mcp_token]
  end
end
