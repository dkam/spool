# frozen_string_literal: true

# Full-text search over messages via SQLite FTS5. See Search::Fts for the
# table, the triggers and why they're ensured at boot rather than in a
# migration.

# Keep the FTS5 virtual table and its shadow tables (messages_fts,
# messages_fts_data, _idx, _docsize, _config) out of the :ruby schema dump.
# They can't be represented there — and worse, Active Record 8.1's SQLite
# dumper crashes on an external-content FTS5 table (its `arguments` come back
# nil, then `nil.split`), truncating db/schema.rb mid-write on every
# db:migrate. Search::Fts.ensure! owns them instead, so nothing is lost.
ActiveRecord::SchemaDumper.ignore_tables |= [/\Amessages_fts(_|\z)/]

Rails.application.config.after_initialize do
  Search::Fts.ensure!
rescue => e
  # The database may not exist yet (db:create) or may be mid-migration. Safe to
  # skip — the next boot retries, and nothing reads the index before then.
  Rails.logger.warn("[messages_fts] skipped: #{e.class}: #{e.message}")
end
