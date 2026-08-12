# frozen_string_literal: true

# Spool's release version — SemVer, bumped by hand when something worth naming
# changes.
#
# This is the single source of truth, and it is deliberately not the same thing
# as `config.x.revision` (see config/initializers/revision.rb). Both are worth
# having, and they answer different questions:
#
#   version   which release is this? Survives a rebuild of the same code, goes
#             in a changelog, is what you say out loud.
#   revision  which commit is this? Precise, automatic, meaningless to read,
#             and the only thing that answers "is what I just built actually
#             running?"
#
# **Bumping this file is what cuts a release.** .github/workflows/build.yml
# triggers on a change to this path on main: it builds the multi-arch image,
# publishes it to ghcr.io, and creates the matching vX.Y.Z git tag. There is no
# separate `git tag` step to forget — see docs/deploy.md.
#
# A pre-release (e.g. "0.2.0-dev") publishes :v0.2.0-dev but does not move
# :latest, so it is safe to build one from a branch.
#
# Lives in config/ rather than lib/ so it can be read without booting Rails:
#   ruby -e "require './config/version'; puts Spool::VERSION"
module Spool
  VERSION = "0.2.0"
end
