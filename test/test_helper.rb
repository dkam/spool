ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# rails/test_help has just loaded the schema into the test database, which drops
# whatever the boot-time initializer created. Re-ensure the FTS5 table and its
# triggers here for the single-process case; parallelize_setup below covers the
# per-worker databases, and only fires once the suite crosses the
# parallelization threshold.
Search::Fts.ensure!

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # The FTS5 virtual table and its triggers can't be represented in the :ruby
    # schema, so neither `db:test:prepare` nor the per-worker database each
    # parallel test process gets creates them. Without this, every search test
    # would quietly return nothing. Same reason config/initializers/messages_fts.rb
    # exists for the real environments.
    parallelize_setup do |_worker|
      Search::Fts.ensure!
    end

    setup do
      # ENV-driven auth configuration is memoised per process; a test that
      # changes it must not leak into the next one.
      SpoolAuthorization.reset_cache!
      Compression::DictStore.reset!
    end

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Runs a block with environment variables set, restoring them afterwards.
    # Used by the auth tests, which are entirely about what ENV says.
    def with_env(vars)
      original = vars.keys.index_with { |k| ENV[k] }
      vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
      SpoolAuthorization.reset_cache!
      yield
    ensure
      original.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
      SpoolAuthorization.reset_cache!
    end
  end
end
