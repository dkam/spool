require "test_helper"

# The header is the one place every agent looks, every time. When mail stops it
# says so there, and otherwise it says nothing at all.
class MailHealthHeaderTest < ActionDispatch::IntegrationTest
  setup do
    # See UiFlowsTest: open mode's stand-in agent, created up front.
    Agent.find_or_create_by!(oidc_sub: "dev-open-mode") do |a|
      a.email = ENV.fetch("SPOOL_DEV_AGENT_EMAIL", "dev@localhost")
      a.name = "Development Agent"
    end
  end

  test "says nothing while mail is moving" do
    with_env("SPOOL_JMAP_TOKEN" => "t", "SPOOL_JMAP_FOLDER" => nil) do
      IngestCursor.polled!("jmap:Spool", at: 1.minute.ago)

      get tickets_path(state: "open")

      assert_response :success
      assert_select "[data-mail-health]", count: 0
    end
  end

  test "says when mail has stopped, and what to do about it" do
    DroppedMail.create!(kind: "failed", reason: "boom", message_id: "<a@x>")

    with_env("SPOOL_JMAP_TOKEN" => "t", "SPOOL_JMAP_FOLDER" => nil) do
      IngestCursor.polled!("jmap:Spool", at: 3.hours.ago)

      get tickets_path(state: "open")

      assert_select "[data-mail-health]" do
        assert_select "li", text: "No mail check for about 3 hours"
        assert_select "li[title*='jmap:rewind']", text: "1 message failed to arrive"
      end
    end
  end
end
