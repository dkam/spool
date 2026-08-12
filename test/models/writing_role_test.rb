# frozen_string_literal: true

require "test_helper"

# Guards the reader/writer split itself.
#
# These tests exist because the same bug has appeared three times: a legitimate
# write on a GET, raising ReadOnlyError. It raises in every environment — the
# middleware sets prevent_writes on ActiveRecord::Base, which every model reads
# through, so separate pools don't soften it — and test is the only place that
# catches it before a user does. The third instance reached production: the OIDC
# callback is a GET, and provisioning an agent on first login raised. So the
# split stays enabled in test (config/environments/test.rb) and these assert it
# behaves.
class WritingRoleTest < ActiveSupport::TestCase
  setup do
    @agent = Agent.create!(oidc_sub: "sub-w", email: "w@example.com")
    @customer = Customer.create!(email: "w@example.com")
    @ticket = Ticket.create!(customer: @customer, last_activity_at: 1.hour.ago)
  end

  # Stands in for what ActiveRecord::Middleware::DatabaseSelector does to a GET.
  def as_a_get_request(&block)
    ActiveRecord::Base.connected_to(role: :reading, prevent_writes: true, &block)
  end

  test "an unwrapped write on a GET raises, so the guard is real" do
    as_a_get_request do
      assert_raises(ActiveRecord::ReadOnlyError) do
        Ticket.create!(customer: @customer, last_activity_at: Time.current)
      end
    end
  end

  test "ApplicationRecord.writing lifts the guard" do
    as_a_get_request do
      ApplicationRecord.writing do
        assert_nothing_raised { @ticket.update!(subject: "written on a GET") }
      end
    end

    assert_equal "written on a GET", @ticket.reload.subject
  end

  # The specific trap: switching role on ApplicationRecord rather than on
  # ActiveRecord::Base clears a flag nobody is reading. If this ever starts
  # passing, ApplicationRecord.writing can be simplified — until then it must
  # keep using ActiveRecord::Base.
  test "switching role on ApplicationRecord alone does NOT lift the guard" do
    as_a_get_request do
      ApplicationRecord.connected_to(role: :writing) do
        assert_equal :writing, ApplicationRecord.current_role
        assert_equal false, ApplicationRecord.current_preventing_writes,
          "ApplicationRecord reports writes are allowed..."
        assert_equal true, ActiveRecord::Base.current_preventing_writes,
          "...but ActiveRecord::Base, whose flag the adapter reads, still forbids them"

        assert_raises(ActiveRecord::ReadOnlyError) { @ticket.update!(subject: "nope") }
      end
    end
  end

  test "marking a ticket read works on a GET without the caller wrapping it" do
    as_a_get_request do
      assert_nothing_raised { @ticket.mark_read!(@agent) }
    end

    refute @ticket.unread_for?(@agent)
  end

  test "provisioning the open-mode agent works on a GET against a fresh database" do
    Agent.where(oidc_sub: "dev-open-mode").delete_all

    controller = Class.new(ApplicationController).new
    agent = as_a_get_request { controller.send(:development_agent) }

    assert_equal "dev-open-mode", agent.oidc_sub
    assert agent.persisted?
  end

  # The instance that reached production. /auth/callback is a GET, so the first
  # login by an agent nobody has provisioned yet is an INSERT on the read-only
  # replica. It raised, the controller's catch-all rescue turned it into
  # "Authentication error. Please try again.", and the redirect back to /login
  # made it look like the provider had rejected the login.
  test "provisioning an agent on a GET works, so a first OIDC login can succeed" do
    agent = as_a_get_request do
      Agent.find_or_provision!(oidc_sub: "sub-first-login", email: "new@example.com", name: "New Agent")
    end

    assert agent.persisted?
    assert_equal "new@example.com", agent.reload.email
  end

  test "updating a changed email or name on a GET works" do
    Agent.create!(oidc_sub: "sub-renamed", email: "old@example.com", name: "Old Name")

    agent = as_a_get_request do
      Agent.find_or_provision!(oidc_sub: "sub-renamed", email: "new@example.com", name: "New Name")
    end

    assert_equal "new@example.com", agent.reload.email
    assert_equal "New Name", agent.name
  end

  # The quiet half of the same bug: this write is inside start_new_session_for's
  # rescue, so a ReadOnlyError here never failed a login — it just logged a
  # mapping failure and left backchannel logout with nothing to find.
  test "the OIDC session mapping is created on a GET" do
    session = as_a_get_request do
      OidcSession.create_for_user(
        oidc_sid: "sid-on-a-get",
        session_id: "session-on-a-get",
        user_email: @agent.email
      )
    end

    assert session.persisted?
    assert_equal session, OidcSession.find_live("sid-on-a-get")
  end

  test "the open-mode agent is not rewritten once it exists" do
    controller = Class.new(ApplicationController).new
    agent = ApplicationRecord.writing { controller.send(:development_agent) }

    # A read, not a write — otherwise every page view is an UPDATE, and on a GET
    # it would raise besides.
    as_a_get_request do
      assert_nothing_raised { assert_equal agent.id, controller.send(:development_agent).id }
    end
  end
end
