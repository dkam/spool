require_relative "boot"

require "rails"

# Selective railtie requires rather than `rails/all`. Active Storage and Action
# Mailbox are deliberately absent: Spool's whole storage design rests on the
# primary SQLite file being the entire application state (see docs/architecture.md),
# and ActionMailbox::InboundEmail stores raw MIME as an Active Storage blob,
# which would put application state outside that file. Inbound mail is parsed
# directly by Ingest::Mail instead — see docs/ingest.md.
#
# Action Text is absent for the same reason (it depends on Active Storage), and
# is not wanted anyway: agents compose plain text.
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_view/railtie"
require "action_cable/engine"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Spool
  class Application < Rails::Application
    # Production must supply a real secret. Development and test fall back to
    # Rails' generated local secret (tmp/local_secret.txt) so bin/rails works
    # without the variable being set.
    if Rails.env.production?
      config.secret_key_base = ENV.fetch("SECRET_KEY_BASE") do
        raise "SECRET_KEY_BASE environment variable is required but not set."
      end
    end

    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # lib/ is autoloaded, which is how `queue_adapter = :tuber` below resolves:
    # Active Job looks up ActiveJob::QueueAdapters::TuberAdapter by constant,
    # and lib/active_job/queue_adapters/tuber_adapter.rb sits at exactly the
    # path Zeitwerk expects for it.
    config.autoload_lib(ignore: %w[assets tasks])

    # Active Job runs on tuber. Enqueues go onto the spool.activejob tube and
    # Ingest::ActiveJobConsumer drains them. See docs/queue.md.
    config.active_job.queue_adapter = :tuber

    # Reader/writer split against the *same* SQLite file. This is not
    # replication — WAL means a committed write is visible to any new reader
    # connection immediately, so the cutover delay is genuinely zero. The point
    # is pool isolation: a slow read can't queue behind a write.
    #
    # Background jobs run outside this middleware, so anything that writes from
    # a job must wrap itself in ApplicationRecord.connected_to(role: :writing)
    # explicitly. Ingest::Writing exists for that.
    config.active_record.database_selector = {delay: 0.seconds}
    config.active_record.database_resolver =
      ActiveRecord::Middleware::DatabaseSelector::Resolver
    config.active_record.database_resolver_context =
      ActiveRecord::Middleware::DatabaseSelector::Resolver::Session

    # SPOOL_HOST is the host authority — a hostname or "host:port", not a URI.
    config.action_mailer.default_url_options = {
      host: ENV.fetch("SPOOL_HOST", "localhost:3000")
    }
  end
end
