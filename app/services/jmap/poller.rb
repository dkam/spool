# frozen_string_literal: true

module Jmap
  # Reads mail from a Fastmail folder onto spool.inbound. All the Spool-specific
  # policy lives here; Jmap::Client below it knows only the protocol.
  #
  # Nothing here writes to the mailbox. Spool reads the folder and remembers how
  # far it got, rather than moving processed mail into a done folder. That is the
  # whole reason the design looks like this: JMAP has no folder-scoped
  # credential, so a token that can move mail out of the support folder can also
  # rewrite every other folder on the account. On a mailbox holding years of
  # customer correspondence, a poller that *cannot* write is worth more than a
  # folder that drains tidily.
  #
  # It also disposes of the `\Seen` hazard docs/todo.md raised, and for a
  # stronger reason than before: nothing here reads or writes flags, so opening
  # the mailbox in a phone client cannot consume the queue — and neither can
  # anything else, because Spool's idea of "processed" lives in Spool's database
  # rather than in the account.
  #
  # The cost of not moving: the folder accumulates instead of draining, so it is
  # an archive rather than a worklist, and a message hand-filed into it with an
  # old receivedAt lands behind the cursor and is never seen. Forward such a
  # message rather than dragging it.
  class Poller
    DEFAULT_FOLDER = "Spool"

    # One poll's worth. Fastmail allows maxObjectsInGet: 4096, so this is not a
    # protocol limit — it caps how much a single run holds in memory and how long
    # it holds its tube connection. A backlog just takes several polls.
    DEFAULT_BATCH_SIZE = 50

    Result = Struct.new(:queued, :failed) do
      def none? = queued.zero? && failed.zero?
    end

    class ConfigurationError < StandardError; end

    # How far Spool has read: the receivedAt of the newest message delivered,
    # plus the ids of every message sharing that exact second.
    #
    # The id list is not redundant. JMAP's `after` filter is inclusive
    # (receivedAt >= after) and receivedAt has one-second granularity, so a
    # timestamp on its own re-fetches the boundary message on every poll — a
    # wasted download a minute forever, and a poller that can never report
    # "nothing new". Normally it holds a single id.
    Cursor = Struct.new(:at, :ids) do
      def self.parse(raw)
        return if raw.blank?

        parsed = JSON.parse(raw)
        new(parsed.fetch("at"), parsed.fetch("ids"))
      rescue JSON::ParserError, KeyError
        # Unreadable means unusable, and there is nothing to repair it from.
        # Starting over re-reads the folder once, which the unique index on
        # messages.message_id makes a no-op. That is much better than a poller
        # that refuses to run until someone edits a database row.
        Rails.logger.warn("[Jmap::Poller] ignoring an unreadable cursor: #{raw.inspect}")
        nil
      end

      def dump = JSON.generate({"at" => at, "ids" => ids})

      def seen?(id) = ids.include?(id)
    end

    def self.configured?
      ENV["SPOOL_JMAP_TOKEN"].present?
    end

    def self.from_env
      raise ConfigurationError, "SPOOL_JMAP_TOKEN is not set" unless configured?

      new(
        client: Client.new(
          token: ENV.fetch("SPOOL_JMAP_TOKEN"),
          session_url: ENV["SPOOL_JMAP_SESSION_URL"]
        ),
        folder: ENV.fetch("SPOOL_JMAP_FOLDER", DEFAULT_FOLDER),
        batch_size: ENV.fetch("SPOOL_JMAP_BATCH_SIZE", DEFAULT_BATCH_SIZE).to_i
      )
    end

    def initialize(client:, folder: DEFAULT_FOLDER, batch_size: DEFAULT_BATCH_SIZE)
      @client = client
      @folder = folder
      @batch_size = batch_size
    end

    def poll
      warn_if_writable
      source_id = mailbox_id!(@folder)
      cursor = Cursor.parse(IngestCursor.position_for(cursor_key))

      emails = pending(source_id, cursor)
      return Result.new(queued: 0, failed: 0) if emails.empty?

      delivered, queued, failed = deliver(emails)
      advance(cursor, delivered)

      Rails.logger.info("[Jmap::Poller] #{@folder}: queued #{queued}, failed #{failed}")

      Result.new(queued: queued, failed: failed)
    end

    private

    # Spool never writes to the mailbox, so a token with write access carries
    # authority it will never use — over every folder on the account, since JMAP
    # scopes tokens per account and not per folder.
    #
    # Not fatal: it polls perfectly well either way. Warned on every poll rather
    # than once, because it costs no extra request (the session is already
    # fetched), it self-clears the moment the token is reissued, and a helpdesk
    # mailbox is not the place to leave spare write access lying around.
    def warn_if_writable
      return if @client.read_only?

      Rails.logger.warn(
        "[Jmap::Poller] this token has write access to the whole account and Spool " \
        "never writes. Reissue it read-only on #{Client::MAIL}."
      )
    end

    # One request: what is in the folder past the cursor, and the blobIds of
    # whatever that found. The back-reference is why this isn't two round trips.
    #
    # Oldest first, so a backlog drains in the order customers wrote in rather
    # than newest-first.
    #
    # `after` is inclusive, so the message the cursor sits on comes back every
    # time and Cursor#seen? is what drops it. Both halves are needed: the filter
    # keeps the query bounded as the folder grows, the id check keeps it from
    # re-delivering. The limit is raised by the number of ids being dropped, or a
    # batch could be filled entirely by messages already seen and the poll would
    # make no progress at all.
    #
    # Argument hashes are string-keyed throughout this class. They are wire
    # fields rather than Ruby options, and "#ids" — the back-reference — could
    # not be a symbol key without mixing two styles in one hash anyway.
    def pending(source_id, cursor)
      filter = {"inMailbox" => source_id}
      filter["after"] = cursor.at if cursor

      responses = @client.call(
        ["Email/query", {
          "accountId" => @client.account_id,
          "filter" => filter,
          "sort" => [{"property" => "receivedAt", "isAscending" => true}],
          "limit" => @batch_size + (cursor&.ids&.size || 0)
        }, "query"],
        ["Email/get", {
          "accountId" => @client.account_id,
          "#ids" => Client.reference("query", "Email/query", "/ids"),
          # blobId is the whole RFC822 message. Asking for nothing else keeps
          # the parsed-email representation out of it entirely — Spool parses
          # the bytes itself, with MimeSplitter, and never trusts a server's
          # idea of what the body was. receivedAt is here only to move the
          # cursor.
          "properties" => ["id", "blobId", "receivedAt"]
        }, "get"]
      )

      responses.fetch("get").fetch("list").reject { |email| cursor&.seen?(email.fetch("id")) }
    end

    # Download each message and put it on the tube.
    #
    # Returns the contiguous run of messages delivered from the start of the
    # batch, alongside the counts. Only that prefix may move the cursor: if the
    # third of five messages fails, the cursor stops at the second, and the next
    # poll re-reads from there. The fourth and fifth are then delivered twice and
    # deduped on message_id — which is the right way to be wrong. Advancing to
    # the newest success instead would step the cursor over a message that never
    # arrived and lose it silently, leaving no trace anywhere.
    def deliver(emails)
      delivered = []
      queued = 0
      failed = 0

      emails.each do |email|
        raw = @client.download(email.fetch("blobId"))

        Ingest::Tuber.put(
          Ingest::Tuber::INBOUND_TUBE,
          {raw: Base64.strict_encode64(raw), source: "jmap"}
        )

        queued += 1
        delivered << email if failed.zero?
      rescue => e
        # One unreadable message must not stop the rest of the batch being
        # queued, so the run continues — but it does hold the cursor, which
        # means a permanently broken message retries forever and loudly rather
        # than silently vanishing. That is the right way round for a helpdesk,
        # but it wants eyes on the log.
        failed += 1
        Rails.logger.error(
          "[Jmap::Poller] failed to deliver #{email["id"]}: #{e.class}: #{e.message}"
        )
      end

      [delivered, queued, failed]
    end

    # The cursor lands on the last message of the delivered prefix, recording
    # every message that shares that exact second by id.
    #
    # Ids from the previous cursor carry over when the second is unchanged. A
    # batch that delivers one more message from a second the cursor already sat
    # in would otherwise forget the earlier one and re-deliver it on every poll
    # from then on.
    def advance(cursor, delivered)
      return if delivered.empty?

      at = delivered.last.fetch("receivedAt")
      ids = delivered.select { |email| email.fetch("receivedAt") == at }.map { |email| email.fetch("id") }
      ids |= cursor.ids if cursor&.at == at

      IngestCursor.advance(cursor_key, Cursor.new(at, ids).dump)
    end

    # Keyed by folder rather than just by source. Pointing SPOOL_JMAP_FOLDER
    # somewhere else is a different queue, and inheriting the old folder's
    # high-water mark would silently skip everything already sitting in the new
    # one.
    def cursor_key
      "jmap:#{@folder}"
    end

    # Mailboxes are few, so fetching all of them and resolving in Ruby is
    # cheaper than a query per path segment. Paths are matched by walking
    # parentId, which is how JMAP models the hierarchy — there is no path
    # property to match against.
    def mailbox_id!(path)
      mailboxes = all_mailboxes

      id = path.split("/").reduce(nil) do |parent_id, segment|
        found = mailboxes.find { |m| m["name"] == segment && m["parentId"] == parent_id }
        break nil unless found

        found["id"]
      end

      # Quoted, not bare: folder names can contain the separator. A real account
      # here has one called "Stores, Affiliates", which a comma-joined list
      # renders as two mailboxes that don't exist.
      id or raise ConfigurationError,
        "no JMAP mailbox at #{path.inspect}. This account has: " \
        "#{mailbox_paths.map(&:inspect).join(", ")}. " \
        "Set SPOOL_JMAP_FOLDER to match, or create the folder."
    end

    # Every mailbox as a "/"-separated path, for the error above. Worth the few
    # lines: the failure this reports is always "the name isn't what you think",
    # and an error that lists the real names answers itself. JMAP has no path
    # property, so the hierarchy is walked back up through parentId.
    def mailbox_paths
      by_id = all_mailboxes.index_by { |m| m["id"] }

      all_mailboxes.map { |mailbox|
        segments = []
        node = mailbox
        while node
          segments.unshift(node["name"])
          node = by_id[node["parentId"]]
        end
        segments.join("/")
      }.sort
    end

    def all_mailboxes
      @all_mailboxes ||= @client
        .call(["Mailbox/get", {"accountId" => @client.account_id, "ids" => nil}, "mailboxes"])
        .fetch("mailboxes")
        .fetch("list")
    end
  end
end
