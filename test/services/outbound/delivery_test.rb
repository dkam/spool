# frozen_string_literal: true

require "test_helper"

# Outbound::Delivery driven directly, no queue and no network in the loop —
# the consumer is thin on purpose. What is Spool's to get right: the MIME is
# built from exactly what compose! stored (threading headers above all),
# delivered_at makes the send idempotent, and enqueueing is skipped rather
# than broken when no transport is configured.
class OutboundDeliveryTest < ActiveSupport::TestCase
  MAILGUN_ENV = {
    "MAILGUN_API_KEY" => "key-test",
    "MAILGUN_DOMAIN" => "mg.example.com",
    "SPOOL_MAILBOX" => "support@example.com"
  }.freeze

  SMTP_ENV = {
    "SMTP_ADDRESS" => "smtp.fastmail.com",
    "SMTP_PORT" => "587",
    "SMTP_USER_NAME" => "booko@booko.com.au",
    "SMTP_PASSWORD" => "secret",
    "SPOOL_MAILBOX" => "support@example.com"
  }.freeze

  # A fake transport duck-typed against the seam (deliver_mime(to:, mime:) →
  # a string for the log line). Stands in for either Mailgun or SMTP.
  class FakeTransport
    attr_reader :deliveries, :name

    def initialize(name: "fake")
      @deliveries = []
      @name = name
    end

    def deliver_mime(to:, mime:)
      @deliveries << {to: to, mime: mime}
      "<queued@#{name}>"
    end
  end

  setup do
    @customer = Customer.create!(email: "dana@fieldworks.co", name: "Dana Whitmore")
    @agent = Agent.create!(oidc_sub: "agent-1", email: "sam@spool.test", name: "Sam")
    @ticket = Ticket.create!(
      customer: @customer, subject: "Outbox stuck", state: "open",
      last_activity_at: 10.minutes.ago
    )
    @inbound = Message.create!(
      ticket: @ticket, direction: "inbound", message_id: "<in-1@fieldworks.co>",
      from_email: "dana@fieldworks.co", sent_at: 10.minutes.ago,
      body: JSON.generate({"text" => "Nothing leaves the outbox.", "html" => nil}),
      body_excerpt: "Nothing leaves the outbox."
    )
    @transport = FakeTransport.new(name: "mailgun")
  end

  # Swap Ingest::Tuber.put for the duration of the block. Hand-rolled because
  # minitest 6 no longer bundles minitest/mock, and this is all stub ever did.
  def stubbing_tuber_put(replacement)
    original = Ingest::Tuber.method(:put)
    Ingest::Tuber.singleton_class.define_method(:put, replacement)
    yield
  ensure
    Ingest::Tuber.singleton_class.define_method(:put, original)
  end

  # Compose is done outside the configured block, so nothing here ever touches
  # a real queue; the env only wraps the delivery under test.
  def with_env(vars)
    previous = vars.keys.index_with { |key| ENV[key] }
    vars.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end

  def with_mailgun_env(&block)
    with_env(MAILGUN_ENV, &block)
  end

  def with_smtp_env(&block)
    with_env(SMTP_ENV, &block)
  end

  test "builds the email from what compose! stored — headers, threading and all" do
    message = Message.compose!(ticket: @ticket, agent: @agent, text: "Fixed — try again?")

    with_mailgun_env { Outbound::Delivery.deliver!(message, transport: @transport) }

    delivery = @transport.deliveries.sole
    assert_equal "dana@fieldworks.co", delivery[:to]

    mail = Mail.read_from_string(delivery[:mime])
    assert_equal ["support@example.com"], mail.from
    assert_equal ["dana@fieldworks.co"], mail.to
    assert_equal message.subject, mail.subject
    assert_equal message.sent_at.to_i, mail.date.to_time.to_i
    # The stored ids go over the wire verbatim — a provider-generated
    # Message-ID would break threading and LoopGuard both.
    assert_equal message.message_id, "<#{mail.message_id}>"
    assert_equal @inbound.message_id, "<#{mail.in_reply_to}>"
    assert_equal @inbound.message_id, "<#{mail.references}>"
    assert_equal "Fixed — try again?", mail.body.decoded.force_encoding(Encoding::UTF_8).strip
  end

  test "stamps delivered_at and skips a second send" do
    message = Message.compose!(ticket: @ticket, agent: @agent, text: "On it.")

    with_mailgun_env do
      assert_equal :delivered, Outbound::Delivery.deliver!(message, transport: @transport)
      assert message.reload.delivered_at.present?

      # A job redelivered after its TTR, or a backfill racing a live send.
      assert_equal :already_delivered, Outbound::Delivery.deliver!(message, transport: @transport)
    end

    assert_equal 1, @transport.deliveries.size
  end

  test "a note can never be delivered" do
    note = Message.compose!(ticket: @ticket, agent: @agent, text: "DNS again.", direction: "note")

    with_mailgun_env do
      assert_raises Outbound::Delivery::NotDeliverable do
        Outbound::Delivery.deliver!(note, transport: @transport)
      end
    end
    assert_empty @transport.deliveries
  end

  test "delivering unconfigured raises rather than pretending" do
    message = Message.compose!(ticket: @ticket, agent: @agent, text: "Hello?")

    assert_not Outbound::Delivery.configured?
    assert_raises Outbound::Delivery::NotConfigured do
      Outbound::Delivery.deliver!(message, transport: @transport)
    end
    assert_nil message.reload.delivered_at
  end

  test "compose! queues an outbound send with a per-message idempotency key" do
    puts_seen = []
    record = ->(tube, payload, **opts) { puts_seen << [tube, payload, opts] }

    message = nil
    with_mailgun_env do
      stubbing_tuber_put(record) do
        message = Message.compose!(ticket: @ticket, agent: @agent, text: "Queued for real.")
      end
    end

    tube, payload, opts = puts_seen.sole
    assert_equal Ingest::Tuber::OUTBOUND_TUBE, tube
    assert_equal({message_id: message.id}, payload)
    assert_equal "outbound-#{message.id}", opts[:idp]
  end

  test "compose! queues nothing for notes, and nothing at all when no transport is configured" do
    never = ->(*, **) { flunk "nothing should reach the queue" }

    stubbing_tuber_put(never) do
      # Unconfigured (test env): even an outbound reply stays stored-only.
      reply = Message.compose!(ticket: @ticket, agent: @agent, text: "Stored only.")

      note = with_mailgun_env do
        Message.compose!(ticket: @ticket, agent: @agent, text: "Internal.", direction: "note")
      end

      # The rows themselves are unaffected by the skipped enqueue.
      assert reply.persisted?
      assert note.persisted?
    end
  end

  test "a queue failure is swallowed — the reply is already saved" do
    boom = ->(*, **) { raise Errno::ECONNREFUSED }

    message = nil
    with_mailgun_env do
      stubbing_tuber_put(boom) do
        message = Message.compose!(ticket: @ticket, agent: @agent, text: "Queue is down.")
      end
    end

    assert message.persisted?
    assert_nil message.delivered_at
  end

  # --- SMTP transport -------------------------------------------------------

  test "configured? is true under SMTP env, and SMTP takes precedence over Mailgun" do
    with_smtp_env do
      assert Outbound::Delivery.smtp_configured?
      assert Outbound::Delivery.configured?

      # When both are set, SMTP wins — the common case for an inbox provider
      # relay. The picked transport is the SMTP one, not Mailgun.
      with_env(MAILGUN_ENV) do
        assert Outbound::Delivery.smtp_configured?
        assert Outbound::Delivery.mailgun_configured?
        assert_kind_of Outbound::Smtp, Outbound::Delivery.transport
      end
    end
  end

  test "SMTP env picks the SMTP transport and delivers via it" do
    smtp = FakeTransport.new(name: "smtp")
    message = Message.compose!(ticket: @ticket, agent: @agent, text: "Via SMTP.")

    with_smtp_env do
      assert_kind_of Outbound::Smtp, Outbound::Delivery.transport
      assert_equal :delivered, Outbound::Delivery.deliver!(message, transport: smtp)
    end

    assert message.reload.delivered_at.present?
    assert_equal 1, smtp.deliveries.size
    assert_equal "dana@fieldworks.co", smtp.deliveries.sole[:to]
  end

  test "a Rejected from any transport buries, not retries — the consumer's rescue is transport-agnostic" do
    rejecting = Class.new do
      def deliver_mime(to:, mime:)
        raise Outbound::Smtp::Rejected, "SMTP refused: 550 no such user"
      end
    end.new

    message = Message.compose!(ticket: @ticket, agent: @agent, text: "Bad recipient.")

    with_smtp_env do
      assert_raises Outbound::Rejected do
        Outbound::Delivery.deliver!(message, transport: rejecting)
      end
    end

    # Rejected means no delivered_at — the consumer would bury this job.
    assert_nil message.reload.delivered_at

    # The base class catches both transport subclasses, so the consumer's
    # `rescue Outbound::Rejected` is the single hook.
    assert Outbound::Smtp::Rejected < Outbound::Rejected
    assert Outbound::Http::Rejected < Outbound::Rejected
  end

  test "a transient SMTP error propagates uncaught for retry, not Rejected" do
    transient = Class.new do
      def deliver_mime(to:, mime:)
        raise Net::SMTPServerBusy, "421 service unavailable"
      end
    end.new

    message = Message.compose!(ticket: @ticket, agent: @agent, text: "Retry me.")

    with_smtp_env do
      # Not Rejected — the consumer's generic rescue retries these.
      assert_raises Net::SMTPServerBusy do
        Outbound::Delivery.deliver!(message, transport: transient)
      end
    end

    assert_nil message.reload.delivered_at
  end
end
