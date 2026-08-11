# frozen_string_literal: true

# Say out loud, once at boot, what the auth configuration actually adds up to —
# and refuse to start on the two combinations that are certainly mistakes.
#
# Every one of these states is otherwise silent: a half-set provider looks like
# an open instance, an empty allowlist looks like a provider problem, and an
# allowlist with no provider looks like it's doing something. A line in the log
# at startup is cheaper than working any of them out from the outside.
#
# after_initialize because SpoolAuthorization is autoloaded.
Rails.application.config.after_initialize do
  state = SpoolAuthorization.oidc_state

  if state == :enforcing && !SpoolAuthorization.allowlist_configured?
    # Fatal, not a warning. An empty allowlist denies everyone, so the app is
    # useless in exactly the way that is hardest to diagnose: the provider round
    # trip succeeds and then the user is told their own address is not
    # authorised, which reads like their fault. Refusing to boot puts the
    # message where the operator is already looking.
    raise <<~MESSAGE
      OIDC is configured but no allowlist is set.

      Every login would be denied after a successful round trip to the provider.
      Set at least one of:

        SPOOL_ALLOWED_USERS=alice@example.com,bob@example.com
        SPOOL_ALLOWED_DOMAINS=example.com

      (Domains match subdomains too, and accept a *. prefix.)
    MESSAGE
  end

  if state == :open && Rails.env.production?
    # Splat can legitimately run open on a trusted network — it holds error
    # traces. Spool holds customers' correspondence, so serving it
    # unauthenticated is never the intended production configuration.
    raise <<~MESSAGE
      No OIDC provider is configured and Spool is running in production.

      An unauthenticated helpdesk exposes every customer's correspondence.
      Set all of: #{SpoolAuthorization::OIDC_VARS.join(", ")}
      plus an allowlist (SPOOL_ALLOWED_USERS and/or SPOOL_ALLOWED_DOMAINS).
    MESSAGE
  end

  case state
  when :misconfigured
    Rails.logger.error(
      "[auth] OIDC is half-configured — missing #{SpoolAuthorization.missing_oidc_vars.join(", ")}. " \
      "The UI returns 503 until all of #{SpoolAuthorization::OIDC_VARS.join(", ")} are set, " \
      "or all are unset to run open in development."
    )
  when :enforcing
    Rails.logger.info "[auth] OIDC enforcing via #{ENV.fetch("OIDC_PROVIDER_NAME", "OIDC")}"
  when :open
    if SpoolAuthorization.allowlist_without_provider?
      Rails.logger.warn(
        "[auth] #{SpoolAuthorization::ALLOWLIST_VARS.join(" / ")} is set but no OIDC provider is " \
        "configured — nothing is enforcing the allowlist."
      )
    end
    Rails.logger.warn "[auth] running OPEN (no OIDC provider). Every request runs as the development agent."
  end
end
