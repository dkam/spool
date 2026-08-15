# frozen_string_literal: true

require "test_helper"

# Outbound::Mailgun against a fake transport — the same arrangement as
# Jmap::Client's tests, and for the same reason: the request shape is the
# contract, and no HTTP stubbing library is needed to assert on it.
class OutboundMailgunTest < ActiveSupport::TestCase
  class FakeHttp
    attr_reader :calls

    def initialize(body: %({"id":"<accepted@mailgun>"}))
      @body = body
      @calls = []
    end

    def post_form(url, fields, basic_auth: nil)
      @calls << {url: url, fields: fields, basic_auth: basic_auth}
      @body
    end
  end

  test "posts the raw MIME to the domain's messages.mime endpoint under basic auth" do
    http = FakeHttp.new
    client = Outbound::Mailgun.new(api_key: "key-test", domain: "mg.example.com", http: http)

    id = client.deliver_mime(to: "dana@fieldworks.co", mime: "raw rfc822 bytes")

    call = http.calls.sole
    assert_equal "https://api.mailgun.net/v3/mg.example.com/messages.mime", call[:url]
    assert_equal ["api", "key-test"], call[:basic_auth]
    assert_equal "dana@fieldworks.co", call[:fields]["to"]
    assert_equal(
      {content: "raw rfc822 bytes", filename: "message.mime", content_type: "message/rfc822"},
      call[:fields]["message"]
    )
    assert_equal "<accepted@mailgun>", id
  end

  test "an api_base override reroutes the send (EU region), trailing slash and all" do
    http = FakeHttp.new
    client = Outbound::Mailgun.new(
      api_key: "key-test", domain: "mg.example.com",
      api_base: "https://api.eu.mailgun.net/", http: http
    )

    client.deliver_mime(to: "dana@fieldworks.co", mime: "bytes")

    assert_equal "https://api.eu.mailgun.net/v3/mg.example.com/messages.mime", http.calls.sole[:url]
  end

  test "a 2xx with an unparseable body is a successful send with no id" do
    http = FakeHttp.new(body: "OK")
    client = Outbound::Mailgun.new(api_key: "key-test", domain: "mg.example.com", http: http)

    assert_nil client.deliver_mime(to: "dana@fieldworks.co", mime: "bytes")
  end
end
