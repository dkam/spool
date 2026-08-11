# frozen_string_literal: true

# Who is allowed in. Ported from splat's SplatAuthorization, with one
# difference: Spool refuses to run open in production (see .oidc_state).
#
# There are no roles. At 1–5 people everyone is an agent and everyone sees
# everything; the only access decision is "is this person on the allowlist".
module SpoolAuthorization
  extend ActiveSupport::Concern

  # The three variables that together stand up a provider. All three or none.
  OIDC_VARS = %w[OIDC_CLIENT_ID OIDC_CLIENT_SECRET OIDC_DISCOVERY_URL].freeze

  ALLOWLIST_VARS = %w[SPOOL_ALLOWED_USERS SPOOL_ALLOWED_DOMAINS].freeze

  class << self
    def authorized?(email)
      return false if email.blank?

      email = email.downcase.strip

      return true if allowed_emails.include?(email)

      domain = email.split("@").last
      allowed_domains.any? { |allowed| domain_matches?(domain, allowed) }
    end

    # Three states, not two:
    #
    #   :open          — no OIDC variables at all. Allowed in development and
    #                    test so the app runs without an IdP; refused at boot in
    #                    production, where an unauthenticated helpdesk would
    #                    expose every customer's correspondence to the internet.
    #   :enforcing     — all three present. Require a session.
    #   :misconfigured — some but not all. Somebody meant to turn auth on and a
    #                    variable is missing or misspelled, and guessing which
    #                    way they meant it is exactly the wrong move.
    def oidc_state
      case OIDC_VARS.count { |var| ENV[var].present? }
      when OIDC_VARS.size then :enforcing
      when 0 then :open
      else :misconfigured
      end
    end

    def oidc_configured? = oidc_state == :enforcing

    def oidc_misconfigured? = oidc_state == :misconfigured

    def oidc_open? = oidc_state == :open

    def missing_oidc_vars
      OIDC_VARS.reject { |var| ENV[var].present? }
    end

    # Whether anyone at all can pass authorized?. Both lists empty denies
    # everyone — the right default, since forgetting one variable must not
    # admit a whole domain — but it's indistinguishable from a provider problem
    # once you're staring at "access denied", so this is checked loudly at boot
    # rather than discovered after a round trip.
    def allowlist_configured?
      allowed_emails.any? || allowed_domains.any?
    end

    def allowlist_without_provider?
      oidc_open? && ALLOWLIST_VARS.any? { |var| ENV[var].present? }
    end

    # Memoised per process, so a test that changes ENV must clear it.
    def reset_cache!
      @allowed_emails = nil
      @allowed_domains = nil
    end

    private

    def allowed_emails
      @allowed_emails ||= split_env("SPOOL_ALLOWED_USERS")
    end

    def allowed_domains
      @allowed_domains ||= split_env("SPOOL_ALLOWED_DOMAINS")
    end

    def split_env(name)
      ENV.fetch(name, "").split(",").map { |v| v.strip.downcase }.reject(&:blank?)
    end

    def domain_matches?(domain, allowed)
      return false if domain.blank? || allowed.blank?

      # Wildcards first, so "*.example.com" is handled before the literal
      # comparisons below can reject it.
      return domain_matches?(domain, allowed.delete_prefix("*.")) if allowed.start_with?("*.")

      return true if domain == allowed

      # Subdomain match: support.example.com is covered by example.com.
      domain.end_with?(".#{allowed}")
    end
  end

  def oidc_configured?
    SpoolAuthorization.oidc_configured?
  end
end
