# frozen_string_literal: true

require "test_helper"
require_relative "../../support/fake_jmap_server"

# The poller against a stateful fake JMAP server, so a second poll really does
# re-query the same folder and has to be filtered out by the cursor rather than
# by an empty fixture. Nothing here touches the network, and nothing touches
# Ingest::Inbound — the poller's contract is "raw bytes onto the tube", and that
# boundary is where the test cuts.
class Jmap::PollerTest < ActiveSupport::TestCase
  setup do
    @server = FakeJmapServer.new
    @spool = @server.add_mailbox("Spool")
    @put = []
  end

  # --- the happy path ------------------------------------------------------

  test "queues each message's raw bytes and leaves the mailbox untouched" do
    @server.add_email(raw_message("first"), @spool)
    @server.add_email(raw_message("second"), @spool)

    result = capture_puts { poller.poll }

    assert_equal 2, result.queued
    assert_equal 0, result.failed
    # The point of the whole design: nothing moved, nothing was flagged, and the
    # token that did this never needed write access.
    assert_equal 2, @server.ids_in(@spool).size
  end

  test "the tube gets base64 of the exact bytes, tagged with its source" do
    raw = raw_message("hello")
    @server.add_email(raw, @spool)

    capture_puts { poller.poll }

    tube, payload = @put.sole
    assert_equal Ingest::Tuber::INBOUND_TUBE, tube
    assert_equal "jmap", payload[:source]
    assert_equal raw, Base64.decode64(payload[:raw])
  end

  test "an empty folder is a no-op" do
    result = capture_puts { poller.poll }

    assert result.none?
    assert_empty @put
  end

  # --- the cursor ----------------------------------------------------------

  test "a second poll finds nothing, because the cursor moved past it" do
    @server.add_email(raw_message("only once"), @spool)

    capture_puts { poller.poll }
    second = capture_puts { poller.poll }

    assert second.none?
    assert_equal 1, @put.size, "the same message must not be queued twice"
  end

  test "a message sharing the cursor's second is delivered, not swallowed by it" do
    # JMAP's `after` filter is inclusive and receivedAt is second-granular, so
    # this is the case a bare timestamp cursor gets wrong — in one direction it
    # re-delivers the boundary message forever, in the other it skips its
    # neighbour. Both messages land here, exactly once each.
    same_second = "2026-08-12T09:00:00Z"
    @server.add_email(raw_message("a"), @spool, received_at: same_second)
    @server.add_email(raw_message("b"), @spool, received_at: same_second)

    first = capture_puts { poller(batch_size: 1).poll }
    second = capture_puts { poller(batch_size: 1).poll }
    third = capture_puts { poller(batch_size: 1).poll }

    assert_equal 1, first.queued
    assert_equal 1, second.queued
    assert third.none?
    assert_equal %w[a b], subjects_put.sort
  end

  test "the cursor is per folder, so repointing the poller doesn't skip mail" do
    other = @server.add_mailbox("Archive")
    @server.add_email(raw_message("spooled"), @spool)
    @server.add_email(raw_message("archived"), other, received_at: "2026-08-01T00:00:00Z")

    capture_puts { poller.poll }
    result = capture_puts { poller(folder: "Archive").poll }

    # Older than the Spool cursor. A single shared high-water mark would have
    # hidden it.
    assert_equal 1, result.queued
    assert_equal %w[spooled archived], subjects_put
  end

  test "an unreadable cursor starts over rather than refusing to poll" do
    @server.add_email(raw_message("recoverable"), @spool)
    IngestCursor.advance("jmap:Spool", "not json")

    result = capture_puts { poller.poll }

    assert_equal 1, result.queued
  end

  # --- ordering and batching ----------------------------------------------

  test "drains oldest first, so a backlog keeps the order customers wrote in" do
    @server.add_email(raw_message("newest"), @spool, received_at: "2026-08-12T12:00:00Z")
    @server.add_email(raw_message("oldest"), @spool, received_at: "2026-08-10T09:00:00Z")
    @server.add_email(raw_message("middle"), @spool, received_at: "2026-08-11T09:00:00Z")

    capture_puts { poller.poll }

    assert_equal %w[oldest middle newest], subjects_put
  end

  test "batch_size caps a run, and the remainder waits for the next poll" do
    3.times { |i| @server.add_email(raw_message("m#{i}"), @spool) }

    first = capture_puts { poller(batch_size: 2).poll }
    second = capture_puts { poller(batch_size: 2).poll }

    assert_equal 2, first.queued
    assert_equal 1, second.queued
    assert_equal %w[m0 m1 m2], subjects_put
  end

  test "a poll is a single API request — query and get are chained" do
    @server.add_email(raw_message("one"), @spool)

    capture_puts { poller.poll }

    # Mailbox/get, then the chained Email/query + Email/get. The second is the
    # claim worth pinning: two method calls, one request.
    chained = @server.requests.find { |calls| calls.first.first == "Email/query" }
    assert_equal ["Email/query", "Email/get"], chained.map(&:first)
  end

  # --- failure -------------------------------------------------------------

  test "a message that cannot be downloaded holds the cursor and is retried" do
    @server.add_email(raw_message("unreadable"), @spool)
    @server.download_error = true

    result = capture_puts { poller.poll }

    assert_equal 0, result.queued
    assert_equal 1, result.failed
    assert_empty @put

    @server.download_error = nil
    assert_equal 1, capture_puts { poller.poll }.queued, "the cursor must not have moved past it"
  end

  test "a message behind a failure still gets through, and is re-delivered later" do
    @server.add_email(raw_message("ok"), @spool)
    broken = @server.add_email(raw_message("broken"), @spool)
    @server.add_email(raw_message("behind"), @spool)
    @server.download_error = @server.blob_of(broken)

    first = capture_puts { poller.poll }

    assert_equal 2, first.queued
    assert_equal 1, first.failed

    # The cursor stopped at "ok", so the next poll re-reads from there. "behind"
    # arrives a second time and message_id dedup absorbs it — the alternative is
    # a cursor that steps over "broken" and loses it with no trace.
    @server.download_error = nil
    capture_puts { poller.poll }

    assert_equal %w[ok behind broken behind], subjects_put
  end

  test "nothing reaches the cursor until its bytes are on the tube" do
    @server.add_email(raw_message("ordering"), @spool)

    # If the cursor advanced first, a crash here would strand the message behind
    # a high-water mark it never actually passed.
    stub_tuber_put(->(*, **) { raise "tube is down" }) { poller.poll }

    assert_nil IngestCursor.position_for("jmap:Spool")
    assert_equal 1, capture_puts { poller.poll }.queued
  end

  test "a missing folder names itself, and lists what the account really has" do
    @server.add_mailbox("Done", parent: @spool)

    error = assert_raises(Jmap::Poller::ConfigurationError) do
      capture_puts { poller(folder: "Nope").poll }
    end

    assert_match(/"Nope"/, error.message)
    # The failure is always "the name isn't what you thought", so the error
    # answers itself rather than sending you to another tool. Nested mailboxes
    # are shown as full paths, which is what the setting expects.
    assert_match(%r{"Spool", "Spool/Done"}, error.message)
  end

  test "a rejected token surfaces as Unauthorized rather than being swallowed" do
    @server.add_email(raw_message("x"), @spool)

    assert_raises(Jmap::Http::Unauthorized) do
      capture_puts { poller(token: "wrong").poll }
    end
  end

  # --- the token Spool wants -----------------------------------------------

  test "a token with write access polls anyway, but says it shouldn't have it" do
    @server.read_only = false
    @server.add_email(raw_message("fine"), @spool)

    logged = capture_logs { capture_puts { poller.poll } }

    assert_equal 1, @put.size
    assert_match(/read-only/, logged)
  end

  test "a read-only token is unremarkable, and logs nothing about it" do
    @server.add_email(raw_message("fine"), @spool)

    logged = capture_logs { capture_puts { poller.poll } }

    assert_no_match(/read-only/, logged)
  end

  # --- configuration -------------------------------------------------------

  test "configured? follows the token, and nothing else" do
    with_env("SPOOL_JMAP_TOKEN" => nil) { assert_not Jmap::Poller.configured? }
    with_env("SPOOL_JMAP_TOKEN" => "t") { assert Jmap::Poller.configured? }
  end

  test "the poll job is a no-op with no token" do
    with_env("SPOOL_JMAP_TOKEN" => nil) { assert_nil Jmap::PollJob.new.perform }
  end

  private

  def poller(folder: "Spool", batch_size: 50, token: "test-token")
    Jmap::Poller.new(
      client: Jmap::Client.new(
        token: token,
        session_url: FakeJmapServer::SESSION_URL,
        http: @server
      ),
      folder: folder,
      batch_size: batch_size
    )
  end

  # Ingest::Tuber is the boundary; the queue itself is docs/queue.md's problem.
  def capture_puts(&block)
    sink = @put
    stub_tuber_put(->(tube, payload, **) { sink << [tube, payload] }, &block)
  end

  # Minitest 6 no longer ships minitest/mock, and one swapped method is not
  # worth a gem. Restores by rebinding the original UnboundMethod, so the real
  # Ingest::Tuber.put survives even when the block raises.
  def stub_tuber_put(handler)
    singleton = Ingest::Tuber.singleton_class
    original = singleton.instance_method(:put)
    singleton.define_method(:put) { |*args, **kwargs| handler.call(*args, **kwargs) }
    yield
  ensure
    singleton.define_method(:put, original)
  end

  def capture_logs
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = original
  end

  def subjects_put
    @put.map { |_, payload| Base64.decode64(payload[:raw])[/Subject: (\S+)/, 1] }
  end

  def raw_message(subject)
    <<~MAIL.b
      From: Ada Lovelace <ada@example.com>
      To: support@example.com
      Subject: #{subject}
      Message-ID: <#{subject}@example.com>
      Date: Tue, 11 Aug 2026 09:14:20 +1000

      Body of #{subject}.
    MAIL
  end
end
