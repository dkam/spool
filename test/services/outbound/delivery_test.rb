# frozen_string_literal: true

require "test_helper"

# Outbound::Delivery driven directly, no queue and no network in the loop —
# the consumer is thin on purpose. What is Spool's to get right: the MIME is
# built from exactly what compose! stored (threading headers above all),
# delivered_at makes the send idempotent, and enqueueing is skipped rather
# than broken when Mailgun isn't configured.
class OutboundDeliveryTest < ActiveSupport::TestCase
  MAILGUN_ENV = {
    "MAILGUN_API_KEY" => "key-test",
    "MAILGUN_DOMAIN" => "mg.example.com",
    "SPOOL_MAILBOX" => "support@example.com"
  }.freeze

  class FakeMailgun
    attr_reader :deliveries

    def initialize
      @deliveries = []
    end

    def deliver_mime(to:, mime:)
      @deliveries << {to: to, mime: mime}
      "<queued@mailgun>"
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
    @mailgun = FakeMailgun.new
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
  def with_mailgun_env
    previous = MAILGUN_ENV.keys.index_with { |key| ENV[key] }
    MAILGUN_ENV.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end

  test "builds the email from what compose! stored — headers, threading and all" do
    message = Message.compose!(ticket: @ticket, agent: @agent, text: "Fixed — try again?")

    with_mailgun_env { Outbound::Delivery.deliver!(message, mailgun: @mailgun) }

    delivery = @mailgun.deliveries.sole
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
      assert_equal :delivered, Outbound::Delivery.deliver!(message, mailgun: @mailgun)
      assert message.reload.delivered_at.present?

      # A job redelivered after its TTR, or a backfill racing a live send.
      assert_equal :already_delivered, Outbound::Delivery.deliver!(message, mailgun: @mailgun)
    end

    assert_equal 1, @mailgun.deliveries.size
  end

  test "a note can never be delivered" do
    note = Message.compose!(ticket: @ticket, agent: @agent, text: "DNS again.", direction: "note")

    with_mailgun_env do
      assert_raises Outbound::Delivery::NotDeliverable do
        Outbound::Delivery.deliver!(note, mailgun: @mailgun)
      end
    end
    assert_empty @mailgun.deliveries
  end

  test "delivering unconfigured raises rather than pretending" do
    message = Message.compose!(ticket: @ticket, agent: @agent, text: "Hello?")

    assert_not Outbound::Delivery.configured?
    assert_raises Outbound::Delivery::NotConfigured do
      Outbound::Delivery.deliver!(message, mailgun: @mailgun)
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

  test "compose! queues nothing for notes, and nothing at all when Mailgun is unconfigured" do
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
end
