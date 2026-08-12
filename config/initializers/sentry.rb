# frozen_string_literal: true

# Error tracking over the Sentry protocol.
#
# Developed against ../splat, which accepts Sentry envelopes and is what this is
# actually pointed at. Nothing here is splat-specific — the DSN decides where
# events go, so hosted Sentry or any other compatible collector works unchanged.
#
# Presence of SENTRY_DSN is the whole switch. No DSN, no init, and every
# `Sentry.capture_exception` in the app is a no-op — which is how development
# and test stay offline without a Rails.env check. Point a laptop at a local
# splat by setting the DSN in .env; that is a supported thing to do, not an
# accident to guard against.
return if ENV["SENTRY_DSN"].blank?

Sentry.init do |config|
  config.dsn = ENV["SENTRY_DSN"]
  config.environment = Rails.env

  # Both halves of "what is running?", joined the way SemVer spells build
  # metadata: "0.2.1+a1b2c3d". The version is the release you say out loud, the
  # revision is the only thing that distinguishes two builds of it — a rebuild
  # of the same version is a different release as far as tracking is concerned.
  # See config/version.rb, which explains why these are separate.
  config.release = "#{Spool::VERSION}+#{Rails.application.config.x.revision}"

  # Never sample errors. This instance handles a support queue, not web scale;
  # a dropped exception is a customer whose mail vanished with no trace.
  config.sample_rate = 1.0

  # A helpdesk's exception payloads would otherwise carry customer
  # correspondence — request bodies, cookies, IPs. With PII off, sentry-ruby
  # omits all three, and what is left is a stack trace and the request line.
  # config/initializers/filter_parameter_logging.rb is a second layer, not the
  # first: it only covers params that get sent at all.
  config.send_default_pii = false

  # Breadcrumbs from the Rails logger only. The HTTP logger would record the
  # OIDC provider round trip on every login, and those URLs carry an
  # authorization code.
  config.breadcrumbs_logger = [:active_support_logger]

  # Noise that says nothing about this application: scanners hitting unrouted
  # paths, and a stale form or a returning tab failing CSRF. sentry-rails
  # already ignores ActiveRecord::RecordNotFound and friends.
  config.excluded_exceptions += [
    "ActionController::RoutingError",
    "ActionController::UnknownFormat",
    "ActionController::InvalidAuthenticityToken"
  ]

  # Performance monitoring, off unless asked for. Compose health-checks /up
  # every ten seconds and Turbo prefetches ticket pages, so an unfiltered rate
  # would make the busiest transactions the two least interesting ones.
  traces_rate = ENV.fetch("SENTRY_TRACES_SAMPLE_RATE", 0.0).to_f
  config.traces_sampler = lambda do |context|
    name = context.dig(:transaction_context, :name).to_s
    next 0.0 if name.start_with?("/up", "/health")

    # Honour an upstream decision when a trace arrives already sampled.
    parent = context[:parent_sampled]
    next (parent ? 1.0 : 0.0) unless parent.nil?

    traces_rate
  end
end

# Correlating an issue with `docker compose logs` needs no configuration:
# sentry-ruby reads action_dispatch.request_id off the Rack env and tags every
# event with it (Sentry::Event#rack_env=), which is the same id Rails prints in
# the log line prefix. Do not be tempted to copy it onto event_id instead — the
# protocol wants exactly 32 hex characters there, and a Rails request id is a
# 36-character dashed UUID.
