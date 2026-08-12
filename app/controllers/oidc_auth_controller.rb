# frozen_string_literal: true

# OIDC login, ported from splat. Direct use of the `openid_connect` gem rather
# than omniauth: fewer moving parts, and the pieces that matter (PKCE, ID token
# verification against the provider's JWKS, backchannel logout) are visible here
# rather than spread across a middleware stack.
#
# Works with any compliant provider. Developed against ../clinch.
# See docs/auth.md.
class OidcAuthController < ApplicationController
  allow_unauthenticated_access only: [:login, :start_oidc, :callback, :backchannel_logout]

  # Asymmetric algorithms only. The JWKS can't verify an HS* token anyway, and
  # naming the acceptable set explicitly is what stops an `"alg": "none"` token
  # being accepted.
  ID_TOKEN_ALGORITHMS = %w[RS256 RS384 RS512 PS256 PS384 PS512 ES256 ES384 ES512].freeze

  # GET /login
  def login
    if authenticated? && params[:authenticate] != "true"
      redirect_to root_path, notice: "You are already signed in."
      return
    end

    # Half-configured is a fault and says so with a 503. Deliberately open is
    # not — it's the documented development default, so it renders 200 and
    # explains itself rather than looking broken.
    status = SpoolAuthorization.oidc_misconfigured? ? :service_unavailable : :ok
    render "login/index", status: status
  end

  # GET /login/start
  def start_oidc
    unless SpoolAuthorization.oidc_configured?
      redirect_to login_path, alert: "Authentication is not configured."
      return
    end

    session[:return_to] = params[:return_to] if params[:return_to].present?
    session[:auth_state] = SecureRandom.hex(16)

    # PKCE (RFC 7636). Not strictly required for a confidential client, but it
    # closes authorization-code interception for free.
    code_verifier = SecureRandom.urlsafe_base64(64).tr("=", "")
    session[:pkce_verifier] = code_verifier
    code_challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(code_verifier), padding: false)

    redirect_to oidc_client.authorization_uri(
      scope: "openid email profile",
      response_type: "code",
      state: session[:auth_state],
      redirect_uri: oidc_client.redirect_uri,
      code_challenge: code_challenge,
      code_challenge_method: "S256"
    ), allow_other_host: true
  end

  # GET /auth/callback
  def callback
    unless SpoolAuthorization.oidc_configured?
      redirect_to login_path, alert: "Authentication is not configured."
      return
    end

    expected_state = session.delete(:auth_state)
    code_verifier = session.delete(:pkce_verifier)

    unless valid_state?(params[:state], expected_state) && code_verifier.present?
      Rails.logger.error "OIDC callback state/PKCE mismatch"
      redirect_to login_path, alert: "Invalid authentication state. Please try again."
      return
    end

    oidc_client.authorization_code = params[:code]
    access_token = oidc_client.access_token!(code_verifier: code_verifier)

    id_token = access_token.id_token
    if id_token.blank?
      redirect_to login_path, alert: "No ID token received from the provider."
      return
    end

    claims = verified_claims(id_token)
    email = claims["email"].to_s.strip.downcase

    unless SpoolAuthorization.authorized?(email)
      Rails.logger.warn "Unauthorized login attempt: #{email}"
      redirect_to login_path, alert: "Access denied. #{email} is not on the allowlist."
      return
    end

    if claims["sub"].blank?
      # Without a stable subject there's no identity to key an agent on.
      Rails.logger.error "OIDC ID token has no sub claim"
      redirect_to login_path, alert: "Your provider did not identify you. Please try again."
      return
    end

    # Provisioning and the session mapping below are both writes on a GET, which
    # the database selector routes to the read-only replica. Agent
    # .find_or_provision! and OidcSession.create_for_user each ask for the
    # writing role themselves, so there is deliberately no wrap here — see the
    # notes on those methods.
    agent = Agent.find_or_provision!(
      oidc_sub: claims["sub"],
      email: email,
      name: claims["name"].presence || claims["preferred_username"].presence
    )

    return_to = session[:return_to]
    start_new_session_for(agent, provider: ENV.fetch("OIDC_PROVIDER_NAME", "OIDC"), sid: claims["sid"])

    redirect_to return_to || root_path, notice: "Welcome, #{agent.display_name}."
  rescue OpenIDConnect::Exception, Rack::OAuth2::Client::Error => e
    Rails.logger.error "OIDC token exchange failed: #{e.class}: #{e.message}"
    redirect_to login_path, alert: "Authentication failed. Please try again."
  rescue JWT::DecodeError => e
    # Covers signature, issuer, audience and expiry failures. The ID token
    # didn't check out, so no session is created.
    Rails.logger.error "OIDC ID token verification failed: #{e.class}: #{e.message}"
    redirect_to login_path, alert: "Could not verify the identity token from your provider."
  rescue => e
    Rails.logger.error "OIDC callback error: #{e.class}: #{e.message}"
    Rails.logger.error e.backtrace.first(10).join("\n") if Rails.env.development?
    redirect_to login_path, alert: "Authentication error. Please try again."
  end

  # DELETE /logout
  def logout
    email = current_user_email
    terminate_session
    Rails.logger.info "Signed out: #{email}" if email
    redirect_to login_path, notice: "You have been signed out."
  end

  # POST /oidc/logout — RP-initiated backchannel logout.
  def backchannel_logout
    logout_token = params[:logout_token]
    if logout_token.blank?
      render json: {error: "Missing logout_token"}, status: :bad_request
      return
    end

    claims = validated_logout_token(logout_token)
    return unless claims # an error response has already been rendered

    terminated = process_backchannel_logout(claims)
    Rails.logger.info "Backchannel logout: sid=#{claims["sid"]} terminated=#{terminated}"

    render json: {status: "ok", sessions_terminated: terminated}
  rescue => e
    Rails.logger.error "Backchannel logout error: #{e.class}: #{e.message}"
    render json: {error: "Internal server error"}, status: :internal_server_error
  end

  private

  def oidc_client
    @oidc_client ||= OpenIDConnect::Client.new(
      identifier: ENV.fetch("OIDC_CLIENT_ID"),
      secret: ENV.fetch("OIDC_CLIENT_SECRET"),
      redirect_uri: "#{request.base_url}/auth/callback",
      authorization_endpoint: discovery_document.fetch("authorization_endpoint"),
      token_endpoint: discovery_document.fetch("token_endpoint"),
      userinfo_endpoint: discovery_document["userinfo_endpoint"]
    )
  end

  # Constant-time, so a state comparison can't be used as an oracle.
  def valid_state?(given, expected)
    given.present? && expected.present? &&
      ActiveSupport::SecurityUtils.secure_compare(given, expected)
  end

  # Verify the ID token rather than merely decoding it. OIDC Core 3.1.3.7 does
  # permit skipping this for the authorization code flow — the token arrived
  # over a direct TLS connection to the token endpoint, not via the browser —
  # but discovery has already handed us the JWKS for backchannel logout, so
  # checking signature, issuer, audience and expiry costs one call and removes
  # the need to re-derive whether that exception applies every time somebody
  # reads this method.
  def verified_claims(id_token)
    JWT.decode(id_token, nil, true, {
      algorithms: ID_TOKEN_ALGORITHMS,
      jwks: jwks,
      iss: expected_issuer,
      verify_iss: true,
      aud: ENV.fetch("OIDC_CLIENT_ID"),
      verify_aud: true,
      verify_expiration: true,
      verify_iat: true
    }).first
  end

  def validated_logout_token(token)
    unverified = JWT.decode(token, nil, false).first

    missing = %w[iss aud iat jti events] - unverified.keys
    if missing.any?
      render json: {error: "Missing claims: #{missing.join(", ")}"}, status: :bad_request
      return nil
    end

    unless unverified.dig("events", "http://schemas.openid.net/event/backchannel-logout")
      render json: {error: "Invalid logout event type"}, status: :bad_request
      return nil
    end

    # Replay protection. The spec puts the window at 24 hours.
    cache_key = "logout_token:#{unverified["jti"]}"
    if Rails.cache.exist?(cache_key)
      Rails.logger.warn "Backchannel logout replay: jti=#{unverified["jti"]}"
      render json: {error: "Replay detected"}, status: :bad_request
      return nil
    end
    Rails.cache.write(cache_key, true, expires_in: 24.hours)

    JWT.decode(token, nil, true, {
      algorithms: ID_TOKEN_ALGORITHMS,
      jwks: jwks,
      iss: expected_issuer,
      verify_iss: true,
      aud: ENV.fetch("OIDC_CLIENT_ID"),
      verify_aud: true,
      verify_iat: true
    }).first
  rescue JWT::DecodeError => e
    Rails.logger.error "Backchannel logout token rejected: #{e.class}: #{e.message}"
    render json: {error: "Invalid logout token"}, status: :bad_request
    nil
  end

  def process_backchannel_logout(claims)
    sessions =
      if claims["sid"].present?
        [OidcSession.find_live(claims["sid"])].compact
      else
        # No sid: the spec allows terminating every session for the subject.
        # Spool keys agents on sub, so that resolves to an email.
        agent = Agent.find_by(oidc_sub: claims["sub"])
        agent ? OidcSession.live_for_email(agent.email).to_a : []
      end

    sessions.each(&:invalidate!)
    sessions.size
  end

  def discovery_document
    @discovery_document ||= JSON.parse(
      Net::HTTP.get(URI.parse(discovery_url))
    )
  end

  def discovery_url
    url = ENV.fetch("OIDC_DISCOVERY_URL")
    return url if url.include?(".well-known")

    "#{url.chomp("/")}/.well-known/openid-configuration"
  end

  # Prefer the issuer the provider declares over one guessed from the discovery
  # URL: they differ often enough (path-suffixed issuers, reverse proxies) that
  # verify_iss would otherwise reject a perfectly good provider. OIDC_ISSUER
  # still wins when set explicitly.
  def expected_issuer
    ENV["OIDC_ISSUER"].presence || discovery_document["issuer"].presence ||
      ENV.fetch("OIDC_DISCOVERY_URL").sub(%r{/?\.well-known/openid-configuration/?\z}, "").chomp("/")
  end

  def jwks
    @jwks ||= begin
      uri = discovery_document["jwks_uri"] or raise "OIDC provider advertises no jwks_uri"
      JWT::JWK::Set.new(JSON.parse(Net::HTTP.get(URI.parse(uri)))["keys"])
    end
  end
end
