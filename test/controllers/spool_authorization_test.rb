# frozen_string_literal: true

require "test_helper"

# The allowlist and the three configuration states. This is entirely a function
# of ENV, so every test drives ENV.
class SpoolAuthorizationTest < ActiveSupport::TestCase
  OIDC = {
    "OIDC_CLIENT_ID" => "spool",
    "OIDC_CLIENT_SECRET" => "secret",
    "OIDC_DISCOVERY_URL" => "https://clinch.example.com"
  }.freeze

  # --- states --------------------------------------------------------------

  test "no OIDC variables at all is open" do
    with_env(OIDC.keys.index_with(nil)) do
      assert_equal :open, SpoolAuthorization.oidc_state
      assert SpoolAuthorization.oidc_open?
      refute SpoolAuthorization.oidc_configured?
    end
  end

  test "all three OIDC variables is enforcing" do
    with_env(OIDC) do
      assert_equal :enforcing, SpoolAuthorization.oidc_state
      assert SpoolAuthorization.oidc_configured?
    end
  end

  test "some but not all is misconfigured, and names what is missing" do
    with_env(OIDC.merge("OIDC_CLIENT_SECRET" => nil)) do
      assert_equal :misconfigured, SpoolAuthorization.oidc_state
      assert SpoolAuthorization.oidc_misconfigured?
      assert_equal ["OIDC_CLIENT_SECRET"], SpoolAuthorization.missing_oidc_vars
    end
  end

  test "an allowlist with no provider is flagged" do
    with_env(OIDC.keys.index_with(nil).merge("SPOOL_ALLOWED_DOMAINS" => "example.com")) do
      assert SpoolAuthorization.allowlist_without_provider?
    end
  end

  # --- the allowlist -------------------------------------------------------

  test "an empty allowlist denies everyone" do
    with_env("SPOOL_ALLOWED_USERS" => nil, "SPOOL_ALLOWED_DOMAINS" => nil) do
      refute SpoolAuthorization.allowlist_configured?
      refute SpoolAuthorization.authorized?("anyone@example.com")
    end
  end

  test "exact email matches, case and whitespace insensitively" do
    with_env("SPOOL_ALLOWED_USERS" => " Alice@Example.COM , bob@example.com ",
      "SPOOL_ALLOWED_DOMAINS" => nil) do
      assert SpoolAuthorization.authorized?("alice@example.com")
      assert SpoolAuthorization.authorized?("  ALICE@example.com ")
      assert SpoolAuthorization.authorized?("bob@example.com")
      refute SpoolAuthorization.authorized?("mallory@example.com")
    end
  end

  test "domain matches cover subdomains" do
    with_env("SPOOL_ALLOWED_USERS" => nil, "SPOOL_ALLOWED_DOMAINS" => "example.com") do
      assert SpoolAuthorization.authorized?("anyone@example.com")
      assert SpoolAuthorization.authorized?("anyone@support.example.com")

      # Must not match a domain that merely ends with the same string.
      refute SpoolAuthorization.authorized?("mallory@notexample.com")
      refute SpoolAuthorization.authorized?("mallory@example.com.evil.test")
    end
  end

  test "a wildcard domain behaves the same as the bare domain" do
    with_env("SPOOL_ALLOWED_USERS" => nil, "SPOOL_ALLOWED_DOMAINS" => "*.example.com") do
      assert SpoolAuthorization.authorized?("anyone@support.example.com")
      assert SpoolAuthorization.authorized?("anyone@example.com")
      refute SpoolAuthorization.authorized?("mallory@elsewhere.test")
    end
  end

  test "a blank email is never authorized" do
    with_env("SPOOL_ALLOWED_DOMAINS" => "example.com") do
      refute SpoolAuthorization.authorized?(nil)
      refute SpoolAuthorization.authorized?("")
      refute SpoolAuthorization.authorized?("   ")
    end
  end
end
