# frozen_string_literal: true

# Say out loud, once at boot, when outbound mail is being sent with TLS
# certificate verification disabled — the one SMTP setting that's a real
# footgun on customer-facing correspondence. A MITM on the SMTP hop to the
# relay could read or tamper with replies going to real customers, and
# nothing else in the app surfaces that the connection is unverified: the
# sends succeed, delivered_at gets stamped, and the thread shows "sent".
#
# A warning rather than a fatal: SMTP_OPENSSL_VERIFY_MODE=none is the
# documented escape hatch for a local relay with a self-signed cert, and
# that's a legitimate setup — just not one that should drift into a
# production deploy unnoticed. The log line puts it where the operator is
# already looking at boot.
Rails.application.config.after_initialize do
  next if ENV["SECRET_KEY_BASE_DUMMY"].present?
  next unless Outbound::Smtp.configured?
  next unless ENV["SMTP_OPENSSL_VERIFY_MODE"].to_s.downcase == "none"

  Rails.logger.warn(
    "[outbound] SMTP_OPENSSL_VERIFY_MODE=none — SMTP certificate verification is " \
    "disabled. Outbound replies to customers are vulnerable to interception on the " \
    "SMTP hop. Only safe against a trusted local relay; remove for any public SMTP server."
  )
end
