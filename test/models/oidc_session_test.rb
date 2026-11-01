# frozen_string_literal: true

require "test_helper"

# The provider keeps one sid for as long as you're signed in there, so logging
# in again after a mapping expires (24 hours) or a backchannel logout
# invalidates it presents the same sid. The old row stays until the hourly
# cleanup, and a second row beside it failed uniqueness: start_new_session_for
# swallowed the error, the login went through with no live mapping, and the
# next page's oidc_session_valid? logged you out again — round and round until
# the cleanup ran. Splat hit exactly this on 2026-11-01.
class OidcSessionTest < ActiveSupport::TestCase
  test "logging in again takes over the sid's expired mapping" do
    OidcSession.create!(oidc_sid: "sid-1", session_id: "old", user_email: "a@example.com", expires_at: 1.minute.ago)

    OidcSession.create_for_user(oidc_sid: "sid-1", session_id: "new", user_email: "a@example.com")

    mapping = OidcSession.find_live("sid-1")
    assert mapping, "no live mapping for the sid after logging in"
    assert_equal "new", mapping.session_id
    assert_equal 1, OidcSession.where(oidc_sid: "sid-1").count
  end

  test "logging in again after a backchannel logout takes the mapping back" do
    OidcSession.create!(oidc_sid: "sid-2", session_id: "old", user_email: "a@example.com", expires_at: 1.day.from_now).invalidate!

    # The callback is a GET, routed to the read-only replica.
    ActiveRecord::Base.connected_to(role: :reading, prevent_writes: true) do
      OidcSession.create_for_user(oidc_sid: "sid-2", session_id: "new", user_email: "a@example.com")
    end

    mapping = OidcSession.find_live("sid-2")
    assert mapping, "no live mapping for the sid after logging in"
    assert_equal "new", mapping.session_id
  end
end
