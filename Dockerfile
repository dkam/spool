# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t spool .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name spool spool

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=4.0.6
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

LABEL org.opencontainers.image.source=https://github.com/dkam/spool

# Rails app lives here
WORKDIR /rails

# Install base packages.
#
# No libvips: there is no Active Storage and no image_processing gem, so
# nothing in this app has ever touched an image. The Rails template ships it by
# default; it is ~40MB of nothing here.
#
# zstd is the CLI, not the library — zstd-ruby is statically linked and needs
# no package. The binary is here for dictionary training (milestone 6), which
# shells out to `zstd --train` because zstd-ruby exposes no training API.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 sqlite3 zstd && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems. git is required because the Gemfile
# pulls beaneater from the tuber fork.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY vendor/* ./vendor/
COPY Gemfile Gemfile.lock ./

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

# Copy application code
COPY . .

# The commit this image was built from, read at boot by
# config/initializers/revision.rb. Declared here rather than at the top because
# an ARG is only in scope for the stage that declares it — put it before the
# FROM and the --build-arg would be silently ignored, which is the failure mode
# where every deploy reports "unknown" and nobody notices for a month.
ARG GIT_SHA=unknown
RUN echo "${GIT_SHA}" > VERSION

# Precompile bootsnap code for faster boot times.
# -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
RUN bundle exec bootsnap precompile -j 1 app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile




# Final stage for app image
FROM base

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

# Copy built artifacts: gems, application
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# Entrypoint prepares the database — but only for the web process, so the
# worker and scheduler roles below never race it to run migrations.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# One image, three processes. Kamal runs the same image with a different CMD
# per role; the queue consumers and the scheduler are separate containers, not
# threads inside Puma, so a wedged consumer can be restarted without dropping
# requests.
#
#   web        ./bin/thrust ./bin/rails server   (the default, below)
#   worker     ./bin/worker all                  (or: mail | maintenance)
#   scheduler  ./bin/scheduler
#
# See docs/queue.md for what each role consumes.
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
