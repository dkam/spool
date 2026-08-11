# frozen_string_literal: true

module Search
  # Ensures the messages_fts FTS5 search index (virtual table + sync triggers)
  # exists. Idempotent.
  #
  # Called at boot (config/initializers/messages_fts.rb) and per worker in
  # parallel tests: virtual tables and triggers can't be represented in the
  # :ruby schema, so neither db:schema:load nor the parallel-test DB setup
  # creates them, and a fresh deploy would silently ship with search returning
  # nothing.
  #
  # Triggers rather than model callbacks because the index must survive bulk
  # writes (insert_all, delete_all) that never instantiate a model.
  module Fts
    module_function

    def ensure!
      return unless ApplicationRecord.connection_pool.db_config.adapter.to_s.include?("sqlite3")

      # with_connection, not .connection: this runs at boot in every process,
      # including bin/worker, where nothing wraps the main thread in a Rails
      # executor. A bare .connection leases the connection to the booting thread
      # and never gives it back, so with a small writer pool the consumer
      # threads that start next block on checkout and time out. Ask for the
      # connection, use it, hand it back.
      ApplicationRecord.writing do
        ApplicationRecord.connection_pool.with_connection do |conn|
          # External content: the index stores only the inverted index and reads
          # column values back out of `messages`, so there is no second copy of
          # the text. content_rowid='id' ties a document to a message row.
          conn.execute(<<~SQL)
            CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
              subject, body_excerpt, content='messages', content_rowid='id'
            )
          SQL

          conn.execute(<<~SQL)
            CREATE TRIGGER IF NOT EXISTS messages_fts_ai AFTER INSERT ON messages BEGIN
              INSERT INTO messages_fts(rowid, subject, body_excerpt)
                VALUES (new.id, new.subject, new.body_excerpt);
            END
          SQL

          # An external-content table can't read the deleted row back, so the old
          # values have to be handed to it explicitly in the 'delete' command.
          conn.execute(<<~SQL)
            CREATE TRIGGER IF NOT EXISTS messages_fts_ad AFTER DELETE ON messages BEGIN
              INSERT INTO messages_fts(messages_fts, rowid, subject, body_excerpt)
                VALUES ('delete', old.id, old.subject, old.body_excerpt);
            END
          SQL

          conn.execute(<<~SQL)
            CREATE TRIGGER IF NOT EXISTS messages_fts_au AFTER UPDATE ON messages BEGIN
              INSERT INTO messages_fts(messages_fts, rowid, subject, body_excerpt)
                VALUES ('delete', old.id, old.subject, old.body_excerpt);
              INSERT INTO messages_fts(rowid, subject, body_excerpt)
                VALUES (new.id, new.subject, new.body_excerpt);
            END
          SQL

          rebuild_if_empty(conn)
        end
      end
    end

    # First boot after the table is created (or after a fresh schema:load):
    # index the rows already present. 'rebuild' re-reads the whole content
    # table, so it only runs while the index is genuinely empty.
    #
    # Emptiness is read from messages_fts_docsize (one row per indexed
    # document), NOT from messages_fts itself. messages_fts is external-content,
    # so querying it reads the *content* table: `SELECT count(*) FROM
    # messages_fts` returns the messages count and a `LIMIT 1` rowid returns a
    # messages id, both completely unchanged by an empty index. Asking
    # messages_fts whether it is indexed is measuring the wrong table.
    def rebuild_if_empty(conn)
      return unless conn.select_value("SELECT 1 FROM messages_fts_docsize LIMIT 1").nil?
      return if conn.select_value("SELECT rowid FROM messages LIMIT 1").nil?

      conn.execute("INSERT INTO messages_fts(messages_fts) VALUES('rebuild')")
      Rails.logger.info("[messages_fts] rebuilt index from existing messages rows")
    end

    # FTS5 treats a lot of punctuation as query syntax, so a user typing
    # `foo@bar.com` or `can't` would otherwise get a SQL error rather than
    # results. Quoting each token as a string literal makes the whole input
    # literal; a trailing * is preserved so prefix search still works.
    def sanitize(query)
      tokens = query.to_s.scan(/[\p{Alnum}_@.'-]+\*?/)
      tokens.map { |t|
        prefix = t.end_with?("*")
        bare = prefix ? t[0..-2] : t
        %("#{bare.gsub('"', '""')}"#{"*" if prefix})
      }.join(" ")
    end

    # Search at ticket granularity: {ticket_id => best matching message id},
    # ordered by relevance, capped at `limit` TICKETS.
    #
    # Deliberately not built on Message.search, which caps at 200 *messages*
    # before anything collapses to tickets. That cap is sane at message
    # granularity and wrong here: 200 messages spread across 12 tickets returns
    # 12 tickets and silently drops every later match, with nothing on the
    # screen to say so. The window function does the collapsing inside SQLite
    # so the cap can be applied to the thing being counted.
    #
    # The message id matters as much as the ticket id. The list previews a
    # ticket's newest message; in a search it has to preview the message that
    # matched, or a hit shows "Thanks, that worked" and you cannot see why it
    # is in your results.
    def ticket_matches(query, limit: 200)
      sanitized = sanitize(query)
      return {} if sanitized.blank?

      rows = ApplicationRecord.connection.select_rows(
        ApplicationRecord.sanitize_sql_array([<<~SQL, sanitized, limit])
          SELECT ticket_id, message_id FROM (
            SELECT ticket_id, message_id, rank,
                   ROW_NUMBER() OVER (PARTITION BY ticket_id ORDER BY rank) AS n
            FROM (
              SELECT messages.ticket_id AS ticket_id,
                     messages.id        AS message_id,
                     bm25(messages_fts) AS rank
              FROM messages_fts
              JOIN messages ON messages.id = messages_fts.rowid
              WHERE messages_fts MATCH ?
            )
          )
          WHERE n = 1
          ORDER BY rank
          LIMIT ?
        SQL
      )

      rows.to_h
    end
  end
end
