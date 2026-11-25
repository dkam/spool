# frozen_string_literal: true

require "test_helper"

# Outbound::Smtp driven directly with a stubbed Mail::SMTP — no network, no
# socket. What is Spool's to get right: the settings surface from env (TLS
# defaults secure, port 465 turns implicit TLS on, no-auth when creds omit),
# the seam hands the envelope recipient and the pre-built MIME to the mail
# gem, and permanent SMTP failures raise Outbound::Smtp::Rejected while
# transient ones propagate for the consumer to retry.
class OutboundSmtpTest < ActiveSupport::TestCase
  SMTP_ENV = {
    "SMTP_ADDRESS" => "smtp.fastmail.com",
    "SMTP_PORT" => "587",
    "SMTP_USER_NAME" => "booko@booko.com.au",
    "SMTP_PASSWORD" => "secret"
  }.freeze

  # Stands in for Mail::SMTP. The mail gem's Mail#deliver! routes through
  # delivery_method.deliver!(mail); `lookup_delivery_method(:smtp)` returns
  # the Mail::SMTP constant, so swapping the constant swaps the class with no
  # socket opened. The gem calls `.new(settings)` itself — a fresh instance
  # per send — so deliveries are recorded on the class, not the instance.
  # `deliver!` returns the SMTP response string for the log line, matching
  # the real mail gem's `return_response` path.
  class FakeSmtp
    class << self
      attr_accessor :deliveries
    end
    self.deliveries = []

    attr_reader :settings

    def initialize(settings)
      @settings = settings
    end

    def deliver!(mail)
      self.class.deliveries << mail
      "250 OK queued as <fake-smtp-id>"
    end

    def self.reset
      self.deliveries = []
    end
  end

  def with_env(vars)
    previous = vars.keys.index_with { |key| ENV[key] }
    vars.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end

  # Swap Mail::SMTP for the given class for the block. lookup_delivery_method
  # reads the constant, so this is enough to route :smtp through the fake.
  def stubbing_smtp(klass)
    original = Mail::SMTP
    Mail.send(:remove_const, :SMTP)
    Mail.const_set(:SMTP, klass)
    yield
  ensure
    Mail.send(:remove_const, :SMTP)
    Mail.const_set(:SMTP, original)
  end

  test "configured? is true when SMTP_ADDRESS is set" do
    assert_not Outbound::Smtp.configured?
    with_env(SMTP_ENV) { assert Outbound::Smtp.configured? }
  end

  test "default settings: STARTTLS auto on 587, verify on, auth from creds" do
    settings = nil
    with_env(SMTP_ENV) { settings = Outbound::Smtp.settings }

    assert_equal "smtp.fastmail.com", settings[:address]
    assert_equal 587, settings[:port]
    assert_equal "booko@booko.com.au", settings[:user_name]
    assert_equal "secret", settings[:password]
    assert_equal :plain, settings[:authentication]
    assert settings[:enable_starttls_auto]
    assert_nil settings[:tls]  # not implicit TLS on 587
    # verify_mode unset => mail gem leaves verify_mode default (VERIFY_PEER).
    assert_nil settings[:openssl_verify_mode]
  end

  test "port 465 turns implicit TLS on and STARTTLS off" do
    settings = nil
    with_env(SMTP_ENV.merge("SMTP_PORT" => "465")) { settings = Outbound::Smtp.settings }

    assert settings[:tls]
    assert_nil settings[:enable_starttls_auto]  # mutually exclusive with tls
  end

  test "omitting user_name and password means no auth" do
    settings = nil
    with_env("SMTP_ADDRESS" => "localhost", "SMTP_PORT" => "25") do
      settings = Outbound::Smtp.settings
    end

    assert_nil settings[:user_name]
    assert_nil settings[:password]
    assert_nil settings[:authentication]
  end

  test "SMTP_ENABLE_STARTTLS_AUTO=false disables STARTTLS upgrade" do
    settings = nil
    with_env(SMTP_ENV.merge("SMTP_ENABLE_STARTTLS_AUTO" => "false")) do
      settings = Outbound::Smtp.settings
    end

    assert_equal false, settings[:enable_starttls_auto]
  end

  test "SMTP_ENABLE_TLS=true forces implicit TLS even on a non-465 port" do
    settings = nil
    with_env(SMTP_ENV.merge("SMTP_ENABLE_TLS" => "true")) do
      settings = Outbound::Smtp.settings
    end

    assert settings[:tls]
    assert_nil settings[:enable_starttls_auto]
  end

  test "SMTP_OPENSSL_VERIFY_MODE is passed through for the mail gem to resolve" do
    settings = nil
    with_env(SMTP_ENV.merge("SMTP_OPENSSL_VERIFY_MODE" => "none")) do
      settings = Outbound::Smtp.settings
    end

    # The mail gem upcases and resolves to VERIFY_NONE itself; we pass the
    # raw string so the escape hatch is the operator's to set explicitly.
    assert_equal "none", settings[:openssl_verify_mode]
  end

  test "deliver_mime hands the envelope recipient and MIME to the mail gem" do
    mime = <<~MIME
      From: support@example.com
      To: dana@fieldworks.co
      Subject: Via SMTP
      Message-ID: <spool-1@spool.test>
      Content-Type: text/plain; charset=UTF-8

      Hello from SMTP.
    MIME

    FakeSmtp.reset
    result = nil
    with_env(SMTP_ENV) do
      stubbing_smtp(FakeSmtp) do
        result = Outbound::Smtp.new.deliver_mime(to: "dana@fieldworks.co", mime: mime)
      end
    end

    delivered = FakeSmtp.deliveries.sole
    assert_equal ["dana@fieldworks.co"], delivered.smtp_envelope_to
    # mail.message_id strips the angle brackets; the raw header carries them.
    assert_equal "spool-1@spool.test", delivered.message_id
    assert_match "Hello from SMTP.", delivered.body.to_s
    assert_match "250 OK", result
  end

  test "permanent SMTP failures raise Outbound::Smtp::Rejected for the consumer to bury" do
    fatal = Class.new(FakeSmtp) do
      def deliver!(mail)
        raise Net::SMTPFatalError, "550 no such user"
      end
    end

    with_env(SMTP_ENV) do
      stubbing_smtp(fatal) do
        assert_raises Outbound::Smtp::Rejected do
          Outbound::Smtp.new.deliver_mime(to: "x@example.com", mime: "From: a@b\r\n\r\nc")
        end
      end
    end
  end

  # Ticket #53: Fastmail refused careerspring@fastmail.com at RCPT TO. Not
  # ours to fix and never going to change — the recipient's address is bad.
  test "a refused recipient address raises RecipientRejected, carrying the server's reply" do
    error = refusing("550 5.1.1 <careerspring@fastmail.com>: Recipient address rejected: User unknown in virtual mailbox table")

    assert_kind_of Outbound::RecipientRejected, error
    assert_kind_of Outbound::Rejected, error, "still a Rejected, so nothing retries it"
    assert_equal "550 5.1.1 <careerspring@fastmail.com>: Recipient address rejected: User unknown in virtual mailbox table",
      error.message
  end

  # RFC 3463: X.1.1 bad mailbox, X.1.2 bad domain, X.1.3 bad syntax, X.1.6
  # moved, X.1.10 null MX, X.2.1 mailbox disabled. Gmail answers multi-line,
  # with a hyphen after the code.
  test "every enhanced status code that blames the address counts as the recipient's" do
    [
      "550-5.1.1 The email account that you tried to reach does not exist.",
      "550 5.1.2 Host unknown",
      "553 5.1.3 Bad recipient address syntax",
      "550 5.1.6 Mailbox has moved",
      "556 5.1.10 Recipient address has null MX",
      "550 5.2.1 The email account that you tried to reach is disabled."
    ].each do |reply|
      assert_kind_of Outbound::RecipientRejected, refusing(reply), reply
    end
  end

  # These are refusals too, but of us — our credentials, our sender address,
  # our content. Fixable on our side, and after the fix the backfill should
  # send the reply, so none of them may mark it undeliverable.
  test "a refusal that isn't about the recipient's address stays a plain Rejected" do
    [
      [Net::SMTPAuthenticationError, "535 5.7.8 Authentication failed"],
      [Net::SMTPFatalError, "553 5.1.8 <support@example.com>: Sender address rejected"],
      [Net::SMTPFatalError, "554 5.7.1 Message rejected as spam"],
      [Net::SMTPFatalError, "550 no such user"] # no enhanced code: can't tell whose fault
    ].each do |error_class, reply|
      error = refusing(reply, error_class: error_class)

      assert_kind_of Outbound::Smtp::Rejected, error, reply
      assert_not_kind_of Outbound::RecipientRejected, error, reply
    end
  end

  test "transient SMTP errors propagate uncaught — the consumer retries them" do
    busy = Class.new(FakeSmtp) do
      def deliver!(mail)
        raise Net::SMTPServerBusy, "421 try later"
      end
    end

    with_env(SMTP_ENV) do
      stubbing_smtp(busy) do
        assert_raises Net::SMTPServerBusy do
          Outbound::Smtp.new.deliver_mime(to: "x@example.com", mime: "From: a@b\r\n\r\nc")
        end
      end
    end
  end

  private

  # The error Outbound::Smtp raises when the server answers `reply`.
  def refusing(reply, error_class: Net::SMTPFatalError)
    smtp = Class.new(FakeSmtp) do
      define_method(:deliver!) { |_mail| raise error_class, reply }
    end

    with_env(SMTP_ENV) do
      stubbing_smtp(smtp) do
        Outbound::Smtp.new.deliver_mime(to: "x@example.com", mime: "From: a@b\r\n\r\nc")
        flunk "expected #{reply.inspect} to be refused"
      rescue Outbound::Rejected => e
        e
      end
    end
  end
end
