# frozen_string_literal: true

# The HTTP edge of Spool's MCP server: authenticate the bearer token, hand the
# JSON-RPC frame to the `mcp` gem, return what it answers. The tools are in
# app/mcp; see docs/mcp.md.
#
# ActionController::API rather than ApplicationController, on purpose. The
# only way in is the token — no session, no cookie, no CSRF token — and a base
# class without sessions means a signed-in browser can't reach this by
# accident. Nor does open mode (no IdP, development only) open it: the UI's
# stand-in agent is a convenience for working on screens, and this endpoint
# can email customers.
#
# Not MCP::Server::Transports::StreamableHTTPTransport, for splat's reason:
# with no server-sent events to stream, the transport would add per-session
# state and Host/Origin allow-lists — the latter a 403 waiting to happen behind
# the proxy — and its DNS-rebinding guard protects servers that take requests
# without credentials, which this one doesn't. Browsers don't attach bearer
# tokens on their own. `handle_json` is the whole protocol without any of it.
class McpController < ActionController::API
  before_action :refuse_half_configured_auth, :authenticate, only: :create

  def create
    answer = SpoolMcp.server(agent: @token.agent).handle_json(request.raw_post)

    # nil is a notification (or only notifications): nothing to answer, and
    # answering anyway is a protocol violation.
    if answer.nil?
      head :accepted
    else
      render json: answer
    end
  end

  # A Streamable HTTP client opens a GET for server-initiated messages, and
  # may DELETE its session on the way out. There are neither here, and 405 is
  # what the spec says to answer.
  def method_not_allowed
    response.headers["Allow"] = "POST"
    head :method_not_allowed
  end

  private

  # The UI refuses everything when OIDC is half-configured (Authentication
  # #render_auth_misconfigured). A token must not be the way around that — the
  # allowlist check it relies on is off in that state too.
  def refuse_half_configured_auth
    return unless SpoolAuthorization.oidc_misconfigured?

    rpc_error(:service_unavailable, -32603, "Spool's sign-in is misconfigured, so it is serving nothing.")
  end

  def authenticate
    @token = McpToken.authenticate(bearer_token)
    return if @token

    # A client that sees 401 shows this to its human, so it says where tokens
    # come from — and nothing about why this one failed.
    response.headers["WWW-Authenticate"] = %(Bearer realm="Spool")
    rpc_error(:unauthorized, -32001,
      "Unauthorized: missing, unknown or revoked token. Generate one at #{settings_url}.")
  end

  def bearer_token
    request.authorization.to_s[/\ABearer\s+(\S+)\z/i, 1]
  end

  def rpc_error(status, code, message)
    render json: {jsonrpc: "2.0", error: {code: code, message: message}, id: nil}, status: status
  end
end
