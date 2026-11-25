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

  # The thread rendered right after Send says "Queued · not yet delivered",
  # and the send lands seconds later in the worker. Unless the open thread is
  # told to refresh, it goes on saying "Queued" until someone reloads.
  test "delivery refreshes the open thread so it stops saying Queued" do
    message = Message.compose!(ticket: @ticket, agent: @agent, text: "On it.")

    with_mailgun_env do
      assert_turbo_stream_broadcasts @ticket do
        Outbound::Delivery.deliver!(message, transport: @transport)
      end
    end
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

  # --- Refused and given up -------------------------------------------------

  # Raises whatever it's given, to drive each failure through the real seam.
  class FailingTransport
    def initialize(error) = @error = error

    def deliver_mime(to:, mime:) = raise(@error)
  end

  REFUSAL = "550 5.1.1 <dana@fieldworks.co>: Recipient address rejected: User unknown in virtual mailbox table"

  # Ticket #53. The reply will never go, so it stops being "not delivered"
  # and becomes something an agent has to look at: tagged, back in the inbox,
  # with the server's words under the reply.
  test "a refused recipient marks the reply undeliverable and puts the ticket back in the inbox" do
    message = Message.compose!(ticket: @ticket, agent: @agent, text: "Fixed it.")
    @ticket.update!(state: "closed")

    outcome = travel_to(1.minute.from_now) do
      with_smtp_env do
        Outbound::Delivery.deliver!(message, transport: FailingTransport.new(Outbound::RecipientRejected.new(REFUSAL)))
      end
    end

    assert_equal :refused, outcome
    message.reload
    assert_nil message.delivered_at
    assert message.undeliverable?
    assert_equal REFUSAL, message.delivery_error

    @ticket.reload
    assert @ticket.tagged?(Tag::UNDELIVERABLE)
    assert_equal "open", @ticket.state
    # Unread again, and at the top of the inbox: something new happened.
    assert_equal message.delivery_failed_at.to_i, @ticket.last_activity_at.to_i
  end

  test "a reply already given up on is never sent" do
    message = Message.compose!(ticket: @ticket, agent: @agent, text: "Too late.")
    message.give_up_delivery!(agent: @agent)

    with_smtp_env do
      assert_equal :undeliverable, Outbound::Delivery.deliver!(message, transport: @transport)
    end

    assert_empty @transport.deliveries
    assert_nil message.reload.delivered_at
  end

  # A refusal of *us* — credentials, sender — and plain network trouble are
  # ours to fix. The reply stays waiting for that fix and the backfill, but
  # the thread can say why it hasn't gone.
  test "any other failure leaves the reply waiting, with the reason recorded" do
    message = Message.compose!(ticket: @ticket, agent: @agent, text: "Hold on.")
    @ticket.update!(state: "pending")

    with_smtp_env do
      assert_raises Outbound::Smtp::Rejected do
        Outbound::Delivery.deliver!(message,
          transport: FailingTransport.new(Outbound::Smtp::Rejected.new("SMTP refused: Net::SMTPAuthenticationError: 535 5.7.8 Authentication failed")))
      end
    end

    message.reload
    assert_not message.undeliverable?
    assert_equal "SMTP refused: Net::SMTPAuthenticationError: 535 5.7.8 Authentication failed", message.delivery_error
    assert_not @ticket.reload.tagged?(Tag::UNDELIVERABLE)
    assert_equal "pending", @ticket.state

    with_smtp_env do
      assert_raises Net::SMTPServerBusy do
        Outbound::Delivery.deliver!(message, transport: FailingTransport.new(Net::SMTPServerBusy.new("421 4.3.2 try later")))
      end
    end
    assert_equal "Net::SMTPServerBusy: 421 4.3.2 try later", message.reload.delivery_error
  end

  test "a reply that goes on a later attempt drops the earlier attempt's error" do
    message = Message.compose!(ticket: @ticket, agent: @agent, text: "Second time lucky.")
    message.update!(delivery_error: "Net::SMTPServerBusy: 421 4.3.2 try later")

    with_smtp_env { Outbound::Delivery.deliver!(message, transport: @transport) }

    assert message.reload.delivered_at
    assert_nil message.delivery_error
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
