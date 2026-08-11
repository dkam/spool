# frozen_string_literal: true

# Session handling for OIDC logins. Ported from splat, adapted so a successful
# login resolves to an Agent row — Spool assigns tickets and attributes replies
# to agents, so the session needs a record, not just an email.
module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
    helper_method :authenticated?, :current_agent, :current_user_email,
      :current_user_name, :current_user_provider
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private

  def authenticated?
    session[:agent_id].present?
  end

  def require_authentication
    return render_auth_misconfigured if SpoolAuthorization.oidc_misconfigured?

    # Development and test with no provider configured: everything is open and
    # requests run as a stand-in agent, so the UI can be worked on without an
    # IdP. Production refuses to reach this state at all — see
    # config/initializers/auth_config_check.rb.
    return if SpoolAuthorization.oidc_open?

    return if authenticated? && oidc_session_valid?

    session[:return_to] = request.fullpath if request.get? && !request.xhr?
    redirect_to login_path
  end

  # Half-configured auth serves nothing rather than silently serving
  # everything. A single misspelled variable would otherwise turn the whole
  # helpdesk into an open one with no signal at all.
  def render_auth_misconfigured
    missing = SpoolAuthorization.missing_oidc_vars
    Rails.logger.error "Refusing request: OIDC is half-configured, missing #{missing.join(", ")}"

    if request.format.html?
      render "errors/auth_misconfigured", layout: false, status: :service_unavailable
    else
      head :service_unavailable
    end
  end

  # The agent for this request. In open mode (development without a provider)
  # this is a stand-in so that `message.agent` and assignment still work.
  def current_agent
    @current_agent ||=
      if SpoolAuthorization.oidc_open?
        development_agent
      elsif session[:agent_id]
        Agent.find_by(id: session[:agent_id])
      end
  end

  DEV_AGENT_SUB = "dev-open-mode"

  # Read first, and only write if the agent genuinely doesn't exist yet.
  #
  # Two reasons. `current_agent` is called on every screen, so provisioning
  # unconditionally meant an UPDATE on every single page view. And every screen
  # is a GET, which the database selector routes to the reading role — so the
  # first page load against a fresh database raised ReadOnlyError rather than
  # rendering. The steady state now touches the database for a read only.
  def development_agent
    Agent.find_by(oidc_sub: DEV_AGENT_SUB) || ApplicationRecord.writing do
      Agent.find_or_provision!(
        oidc_sub: DEV_AGENT_SUB,
        email: ENV.fetch("SPOOL_DEV_AGENT_EMAIL", "dev@localhost"),
        name: "Development Agent"
      )
    end
  end

  def current_user_email = current_agent&.email

  def current_user_name = current_agent&.display_name

  def current_user_provider = session[:provider]

  def start_new_session_for(agent, provider:, sid: nil)
    # Rotate the session id on privilege change, so a session fixated before
    # login can't be reused after it.
    reset_session

    session[:agent_id] = agent.id
    session[:provider] = provider
    session[:authenticated_at] = Time.current
    session[:oidc_sid] = sid if sid.present?

    return if sid.blank?

    OidcSession.create_for_user(
      oidc_sid: sid,
      session_id: session.id&.to_s || request.session_options[:id],
      user_email: agent.email
    )
    Rails.logger.info "Created OIDC session mapping: sid=#{sid}, email=#{agent.email}"
  rescue => e
    # Losing the backchannel-logout mapping degrades logout; it must not cost
    # the user their login.
    Rails.logger.error "Failed to create OIDC session mapping: #{e.message}"
  end

  def terminate_session
    if session[:oidc_sid].present?
      begin
        OidcSession.find_live(session[:oidc_sid])&.destroy
      rescue => e
        Rails.logger.error "Failed to remove OIDC session mapping: #{e.message}"
      end
    end

    reset_session
  end

  # Has the IdP revoked this session out from under us (backchannel logout from
  # another device)? Only meaningful when the provider issued a `sid`.
  def oidc_session_valid?
    return true if session[:oidc_sid].blank?

    if OidcSession.find_live(session[:oidc_sid]).nil?
      Rails.logger.info "OIDC session invalidated, forcing logout: sid=#{session[:oidc_sid]}"
      reset_session
      flash[:alert] = "Your session was ended from another device. Please log in again."
      return false
    end

    true
  rescue => e
    # A database hiccup while checking must not log everyone out.
    Rails.logger.error "Error checking OIDC session validity: #{e.message}"
    true
  end
end
