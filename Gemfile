source "https://rubygems.org"

gem "rails", "~> 8.1.3", ">= 8.1.3.1"

# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use sqlite3 as the database for Active Record
gem "sqlite3", ">= 2.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Use Tailwind CSS [https://github.com/rails/tailwindcss-rails]
gem "tailwindcss-rails"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[windows jruby]

# Database-backed adapters for Rails.cache and Action Cable, each in its own
# SQLite file. Solid Queue is deliberately absent — Active Job runs on tuber
# via lib/active_job/queue_adapters/tuber_adapter.rb. See docs/queue.md.
gem "solid_cache"
gem "solid_cable"

# Tuber/beanstalkd client. The tuber fork adds reserve_batch and the con:/idp:
# put options on top of upstream beaneater 1.1.4, so we track the branch rather
# than rubygems. Same dependency splat uses.
gem "beaneater", git: "https://github.com/dkam/beaneater.git", branch: "tuber"

# Drives the recurring scheduler (config/schedule.yml → tuber).
gem "rufus-scheduler", "~> 3.9"

# Zstd compression for message headers and bodies, with corpus-trained
# dictionaries. See docs/compression.md.
gem "zstd-ruby"

# MIME parsing. Rails already depends on `mail` through Action Mailer; naming it
# explicitly because the ingest pipeline is a first-class consumer of it, not an
# incidental one.
gem "mail"

# Strips quoted history off a reply to produce messages.body_excerpt.
gem "email_reply_parser"

# OpenID Connect authentication (direct, no omniauth). See docs/auth.md.
gem "openid_connect"

# JWT verification for ID tokens and backchannel logout tokens.
gem "jwt"

# Pagination for the ticket list.
gem "pagy", "~> 43.0"

# Load environment variables from .env
gem "dotenv-rails", groups: [:development, :test]

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[mri windows], require: "debug/prelude"

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Audits gems for known security defects.
  gem "bundler-audit", require: false

  # Ruby style guide, linter, and formatter [https://github.com/standardrb/standard]
  gem "standard", "~> 1.51", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"
end
