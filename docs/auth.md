# Authentication

OIDC only, via the `openid_connect` gem used directly — no omniauth. Ported from
splat, which has been running this shape in production.

**There is no password column, no registration and no reset flow. Their absence
is a feature; don't add one later by accident.**

Customers never authenticate. There is no portal.

There are **no roles**. At 1–5 people everyone is an agent and everyone sees
everything.

## Configuration

| Variable | Meaning |
| --- | --- |
| `OIDC_CLIENT_ID` | Client identifier |
| `OIDC_CLIENT_SECRET` | Client secret |
| `OIDC_DISCOVERY_URL` | Issuer URL, with or without `/.well-known/openid-configuration` |
| `OIDC_PROVIDER_NAME` | Display name on the login button (default "OIDC") |
| `OIDC_ISSUER` | Override the expected `iss`; rarely needed |
| `SPOOL_ALLOWED_USERS` | Comma-separated emails |
| `SPOOL_ALLOWED_DOMAINS` | Comma-separated domains; matches subdomains, accepts `*.` |
| `SPOOL_DEV_AGENT_EMAIL` | Identity used in open mode (default `dev@localhost`) |

Redirect URI to register with the provider: `https://your-host/auth/callback`.
The host must be the one in `SPOOL_HOST`, and the scheme must be https — a
mismatch is rejected by the *provider*, so it reads as a problem with them
rather than with the deployment. `compose.yml` derives the certificate hostname
from `SPOOL_HOST` for that reason.

Developed against [clinch](../../clinch), but nothing is provider-specific —
any compliant provider works. `.env.example` carries discovery URLs for
Authentik, Keycloak, Google, Okta and Entra ID as a starting point.

## Three configuration states

`SpoolAuthorization.oidc_state` returns one of:

- **`:enforcing`** — all three OIDC variables present. Require a session.
- **`:open`** — none of them present. Everything is served and every request
  runs as a stand-in agent, so the UI can be worked on without an IdP.
- **`:misconfigured`** — some but not all. Somebody meant to turn auth on and a
  variable is missing or misspelled.

The third state exists because guessing is the wrong move in both directions. A
single typo would otherwise silently turn a protected helpdesk into an open one,
with no signal at all. Instead the UI returns **503** and names the missing
variables (`app/views/errors/auth_misconfigured.html.erb`).

## Two configurations that refuse to boot

`config/initializers/auth_config_check.rb` raises, rather than warns, on:

1. **OIDC configured with no allowlist.** An empty allowlist denies everyone, so
   the app is useless in the way that is hardest to diagnose: the provider round
   trip succeeds and then the user is told their own address isn't authorised,
   which reads like their fault. Refusing to boot puts the message where the
   operator is already looking.

2. **Open mode in production.** Splat can legitimately run open on a trusted
   network — it holds error traces. Spool holds customers' correspondence, so
   serving it unauthenticated is never the intended production configuration.

Everything else is logged at boot, loudly, including a warning when an allowlist
is set with no provider to enforce it.

## The login flow

```
GET  /login          → login page (503 if misconfigured)
GET  /login/start    → state + PKCE verifier into session, redirect to provider
GET  /auth/callback  → verify state, exchange code, verify ID token,
                       check allowlist, find-or-provision Agent, start session
DELETE /logout       → terminate session
POST /oidc/logout    → backchannel logout from the provider
```

### PKCE

Not strictly required for a confidential client, but it closes authorization-code
interception for free. Verifier in the session, S256 challenge to the provider.

### The ID token is verified, not merely decoded

OIDC Core 3.1.3.7 permits skipping verification for the authorization code flow
— the token arrived over a direct TLS connection to the token endpoint, not via
the browser. But discovery has already handed us the JWKS for backchannel
logout, so checking signature, issuer, audience and expiry costs one call and
removes the need to re-derive whether that exception applies every time somebody
reads the method.

`ID_TOKEN_ALGORITHMS` names the acceptable asymmetric algorithms explicitly.
That list is what stops an `"alg": "none"` token being accepted.

The expected issuer prefers what the provider *declares* in its discovery
document over one guessed from the discovery URL — they differ often enough
(path-suffixed issuers, reverse proxies) that `verify_iss` would otherwise
reject a perfectly good provider.

State comparison uses `ActiveSupport::SecurityUtils.secure_compare`.

## Agents are provisioned by logging in

There is no invite flow and no admin screen. `Agent.find_or_provision!` runs
after the allowlist check has passed.

**Keyed on the `sub` claim, not email.** An IdP can change someone's email
address, and the same person must remain the same agent when it does — otherwise
their tickets are orphaned behind a new row. Email is stored too (it's what the
allowlist matches and what the UI shows) but `sub` is the identity.

A login with no `sub` claim is refused: there is no identity to key on.

`reset_session` is called before establishing the new session, so a session
fixated before login can't be reused after it.

## Backchannel logout

`POST /oidc/logout` accepts a signed logout token from the provider and
invalidates the matching `OidcSession` rows, so signing out on one device ends
the session here too.

Validated: required claims present, the backchannel-logout event type present,
`jti` not seen before (replay protection, cached 24 hours per the spec), then
full signature/issuer/audience verification against the JWKS.

`OidcSession#invalidate!` sets `expires_at` into the past rather than deleting
the row — the row is what a later request consults to discover its session was
revoked elsewhere, so it has to outlive the logout long enough to be found.
`CleanupExpiredOidcSessionsJob` sweeps hourly (`config/schedule.yml`).

Sessions where the provider issued no `sid` fall back to invalidating every live
session for that subject's agent.

## Helpers available in controllers and views

```ruby
authenticated?          # boolean
current_agent           # Agent, or the stand-in agent in open mode
current_user_email      # current_agent&.email
current_user_name       # current_agent&.display_name
current_user_provider   # OIDC_PROVIDER_NAME as recorded at login
```

Skip the filter on an action with `allow_unauthenticated_access only: [...]`.
