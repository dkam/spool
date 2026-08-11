# frozen_string_literal: true

require "test_helper"

# Guards the reader/writer split itself.
#
# These tests exist because the same bug appeared twice: a legitimate write on a
# GET, raising ReadOnlyError. Test is the only environment that can catch it —
# in development and production the roles are separate pools and an unwrapped
# write quietly succeeds against the replica connection. So the split stays
# enabled in test (config/environments/test.rb) and these assert it behaves.
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
