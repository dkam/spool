# frozen_string_literal: true

require "test_helper"

class MailHealthTest < ActiveSupport::TestCase
  JMAP = {"SPOOL_JMAP_TOKEN" => "t", "SPOOL_JMAP_FOLDER" => nil}.freeze
  SMTP = {"SMTP_ADDRESS" => "smtp.example.com", "SPOOL_MAILBOX" => "support@example.com",
          "MAILGUN_API_KEY" => nil}.freeze

  test "nothing to say while mail is moving" do
    with_env(JMAP.merge(SMTP)) do
      IngestCursor.polled!("jmap:Spool", at: 1.minute.ago)

      assert MailHealth.new.ok?
    end
  end

  # The six-week outage: the scheduler kept firing, nothing polled, and
  # nothing anywhere said so.
  test "a poller that has gone quiet is a problem" do
    with_env(JMAP) do
      IngestCursor.polled!("jmap:Spool", at: 2.hours.ago)

      assert_equal ["No mail check for about 2 hours"], MailHealth.new.problems.map(&:summary)
    end
  end

  test "a poller that has never run is a problem" do
    with_env(JMAP) do
      assert_equal ["Mail has never been checked"], MailHealth.new.problems.map(&:summary)
    end
  end

  test "no token means no poller, and nothing to be late" do
    with_env("SPOOL_JMAP_TOKEN" => nil) do
      assert MailHealth.new.ok?
    end
  end

  test "mail given up on is a problem, and mail turned away isn't" do
    DroppedMail.create!(kind: "failed", reason: "boom", message_id: "<a@x>")
    DroppedMail.create!(kind: "failed", reason: "boom", message_id: "<b@x>")
    DroppedMail.create!(kind: "rejected", reason: "precedence: bulk", message_id: "<c@x>")

    with_env("SPOOL_JMAP_TOKEN" => nil) do
      assert_equal ["2 messages failed to arrive"], MailHealth.new.problems.map(&:summary)
    end
  end

  test "a reply that should have gone by now is a problem" do
    reply_composed(20.minutes.ago)
    reply_composed(1.minute.ago) # still within its retries

    with_env(SMTP.merge("SPOOL_JMAP_TOKEN" => nil)) do
      assert_equal ["1 reply not delivered"], MailHealth.new.problems.map(&:summary)
    end
  end

  # With no transport a reply is stored by design; nothing was going to send it.
  test "an undelivered reply is not a problem when nothing is configured to send it" do
    reply_composed(20.minutes.ago)

    with_env("SMTP_ADDRESS" => nil, "MAILGUN_API_KEY" => nil, "SPOOL_JMAP_TOKEN" => nil) do
      assert MailHealth.new.ok?
    end
  end

  private

  def reply_composed(at)
    @ticket ||= Ticket.create!(customer: Customer.create!(email: "dana@fieldworks.co"),
      subject: "Outbox", state: "open", last_activity_at: 1.hour.ago)
    Message.create!(ticket: @ticket, direction: "outbound", message_id: "<out-#{at.to_i}@spool.test>",
      sent_at: at, body: JSON.generate({"text" => "Hi", "html" => nil}), body_excerpt: "Hi")
  end
end
