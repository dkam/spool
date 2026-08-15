# frozen_string_literal: true

require "mail"

module Outbound
  # The SMTP transport, a peer of Outbound::Mailgun. Same seam: hand over a
  # fully-built RFC822 message and an envelope recipient, get back something
  # for the log line. Delivery builds the MIME (Message-ID, threading, From:,
  # To:) and this owns nothing but the SMTP send — building a Mail::SMTP
  # delivery method from env, mapping permanent SMTP failures to Rejected so
  # the consumer buries rather than cycling, and letting transient trouble
  # (421, ECONNREFUSED, timeouts) fall through to retry.
  #
  # Uses the `mail` gem's Mail::SMTP directly rather than ActionMailer, so the
  # outbound path pulls in no mailer framework — just the MIME library Rails
  # already depends on. The settings surface is the same one ActionMailer's
  # smtp_settings understands, hence the env var names (SMTP_ADDRESS etc.).
  class Smtp
    # A permanent SMTP refusal — bad credentials, a 5xx, a recipient the
    # server refuses. Retrying the same bytes fails the same way, so the
    # consumer buries. Subclasses Outbound::Rejected so the transport-agnostic
    # rescue catches it alongside Outbound::Http::Rejected.
    class Rejected < Outbound::Rejected; end

    DEFAULT_PORT = 587
    IMPLICIT_TLS_PORT = 465
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 30

    # Net::SMTP errors that won't change on retry. SMTPServerBusy (421) and
    # ProtoRetriableError (4xx) are deliberately not here — those are the
    # transient ones worth a retry before burying.
    PERMANENT_ERRORS = [
      Net::SMTPAuthenticationError,
      Net::SMTPSyntaxError,
      Net::SMTPFatalError,
      Net::SMTPUnsupportedCommand
    ].freeze

    def self.configured?
      ENV["SMTP_ADDRESS"].present?
    end

    # Builds the Mail::SMTP settings hash from env. TLS defaults to secure:
    # STARTTLS auto on 587, implicit TLS on 465, and certificate verification
    # on (the mail gem leaves verify_mode unset, which Net::SMTP treats as
    # VERIFY_PEER). SMTP_OPENSSL_VERIFY_MODE=none disables verification — the
    # one escape hatch for a local relay with a self-signed cert; a boot
    # warning surfaces it so it can't drift into production unnoticed.
    def self.settings
      port = ENV.fetch("SMTP_PORT", DEFAULT_PORT).to_i
      implicit_tls = port == IMPLICIT_TLS_PORT

      s = {
        address: ENV.fetch("SMTP_ADDRESS"),
        port: port,
        domain: ENV["SMTP_DOMAIN"] || "localhost.localdomain",
        open_timeout: OPEN_TIMEOUT,
        read_timeout: READ_TIMEOUT
      }

      if ENV["SMTP_USER_NAME"].present?
        s[:user_name] = ENV["SMTP_USER_NAME"]
        s[:password] = ENV["SMTP_PASSWORD"]
        s[:authentication] = ENV.fetch("SMTP_AUTHENTICATION", "plain").to_sym
      end

      if implicit_tls || ENV["SMTP_ENABLE_TLS"] == "true"
        s[:tls] = true
      else
        s[:enable_starttls_auto] = (ENV["SMTP_ENABLE_STARTTLS_AUTO"] != "false")
      end

      if ENV["SMTP_OPENSSL_VERIFY_MODE"].present?
        s[:openssl_verify_mode] = ENV["SMTP_OPENSSL_VERIFY_MODE"]
      end

      s
    end

    def initialize(settings: self.class.settings)
      @settings = settings
    end

    # `to` is the envelope recipient; the headers inside `mime` are what the
    # customer sees. Returns the SMTP server's final response string, useful
    # only for the log line — the equivalent of Mailgun's queue id.
    def deliver_mime(to:, mime:)
      mail = Mail.new(mime)
      mail.smtp_envelope_to = [to]
      mail.delivery_method :smtp, @settings.merge(return_response: true)
      response = mail.deliver!
      response.to_s.presence || "sent"
    rescue *PERMANENT_ERRORS => e
      raise Rejected.new("SMTP refused: #{e.class}: #{e.message}")
    end
    # Transient errors (Net::SMTPServerBusy 421, Net::ProtoRetriableError,
    # Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout) propagate
    # uncaught — the consumer retries them, then buries via MAX_RETRIES.
  end
end
