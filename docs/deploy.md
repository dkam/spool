# Build, versioning and release

How Spool gets from a commit to a running container, and where the version
number comes from.

## Two numbers, not one

They answer different questions and both are worth having.

| | Where | Set by | Answers |
| --- | --- | --- | --- |
| **version** | `config/version.rb` → `Spool::VERSION` | a human, by hand | *which release is this?* |
| **revision** | `config.x.revision` | the build, from `--build-arg GIT_SHA` | *is what I built actually running?* |

The revision is precise, automatic and meaningless to read. The version survives
a rebuild of the same code, goes in a changelog, and is what you say out loud.
Conflating them costs you one of the two.

`config/version.rb` lives in `config/` rather than `lib/` so it can be read
without booting Rails, which is how the build workflow gets at it:

```bash
ruby -e "require './config/version'; puts Spool::VERSION"
```

## Cutting a release

**Edit `Spool::VERSION`, commit, push to main.** That is the whole procedure.

`.github/workflows/build.yml` triggers on a change to that one path and does the
rest: builds `linux/amd64` and `linux/arm64` natively, stitches them into one
manifest, publishes `ghcr.io/dkam/spool:vX.Y.Z` (plus `:latest`), creates the
`vX.Y.Z` git tag, and opens a GitHub Release.

A **pre-release** — any version containing a hyphen, e.g. `0.2.0-dev` —
publishes `:v0.2.0-dev`, does *not* move `:latest`, and creates no git tag. Safe
to build from a branch.

### Why the version bump is the trigger, and not a tag

There are three ways to do this and only one of them has a single source of
truth.

1. **Tag-driven.** `git tag v1.2.0 && git push --tags`, CI fires on `tags: v*`
   and reads `github.ref_name`. The version exists only in git, so the running
   app cannot report its own version without being told, and the release is not
   reviewable — a tag has no diff.
2. **File-driven** (this repo). The constant is the truth. The bump is an
   ordinary commit you can review, revert and blame, and the app can read it at
   runtime with no git available.
3. **SHA-only.** Build every push. Honest, but there is no human name for
   anything, so "which release broke it" has no answer.

The failure mode of (2) as splat and clinch currently practise it is worth
naming, because it is why the `tag` job exists here: **splat's
`config/version.rb` reads 1.15.0 while its newest git tag is v1.7.8.** The image
tags kept moving and the git tags stopped, because tagging was a separate manual
step and manual steps stop happening. Making the tag a consequence of the
release rather than a chore beside it removes the whole class.

## What CI runs

`ci.yml` on every push and PR:

| Job | Does |
| --- | --- |
| `scan_ruby` | Brakeman, bundler-audit |
| `scan_js` | `importmap audit` |
| `lint` | `bin/standardrb` |
| `test` | `bin/rails test` |
| `system-test` | `bin/rails test:system`, uploads screenshots on failure |
| `build-image` | builds the production image, amd64, no push |

`build-image` is a smoke test, not a publish. It exists because without it the
Dockerfile is exercised for the first time *by the release itself*, which is the
worst possible moment to find out it doesn't work — see below.

## Compiling assets is not serving traffic

Three separate checks each independently made this app impossible to build into
an image, and none of them was visible from the test suite, because **nothing
else ever boots in `RAILS_ENV=production`**. All three failed at
`assets:precompile`, which deliberately boots production with no runtime
configuration at all.

1. `config/application.rb` read `ENV["SECRET_KEY_BASE"]` directly and raised.
   Rails sets `SECRET_KEY_BASE_DUMMY=1` for exactly this case; reading the
   environment bypassed the mechanism provided to solve it.
2. `config/environments/production.rb` still configured `solid_queue`, left over
   from the Rails template and long since replaced by tuber. `NoMethodError`.
3. `config/initializers/auth_config_check.rb` refused to boot without OIDC —
   correct at runtime, fatal during a build.

The rule that resolves all three: **a check that guards serving traffic must not
fire while compiling assets.** `SECRET_KEY_BASE_DUMMY` is the signal Rails
itself sets to mean "this boot will never serve a request", so it is the
condition used in both places, and `test/config/build_boot_test.rb` pins that
the exemption stays narrow. The security guards still refuse a real
unauthenticated production boot — verified against the built image, not
reasoned about.

## The image

One image, three processes. Kamal runs the same image per role with a different
command, so a wedged consumer restarts without dropping requests.

```
web        ./bin/thrust ./bin/rails server     (the default CMD)
worker     ./bin/worker all                    (or: mail | maintenance)
scheduler  ./bin/scheduler
```

`bin/docker-entrypoint` runs `db:prepare` **only** for the web process, so the
worker and scheduler never race it to migrate.

Two deliberate departures from the generated Dockerfile:

- **No `libvips`.** There is no Active Storage and no `image_processing` gem;
  nothing in this app has ever touched an image. It was ~40MB of nothing.
- **`zstd` added.** The CLI, not the library — `zstd-ruby` is statically linked.
  The binary is for dictionary training (milestone 6), which shells out to
  `zstd --train` because zstd-ruby exposes no training API.

## Consolidating the other repos

Surveyed at the time of writing, six repos used four schemes:

| Repo | Tags | Version file |
| --- | --- | --- |
| splat | `v1.7.8` (SemVer) | `config/version.rb` — **1.15.0, 8 ahead of the tags** |
| clinch | `v0.16.2` (SemVer) | `config/initializers/version.rb` — 0.17.1 |
| booko | `v9.9` (major.minor) | none |
| covers | marker tags only | none |
| shopo | `2024.01` (CalVer) | `config/version.rb` — **0.6.2, a different scheme entirely** |
| gr | `2025.01` (CalVer) | none |

The recommendation is what this repo now does, because it is splat's and
shopo's best ideas with the drift removed:

1. **SemVer in `config/version.rb`**, requirable without Rails.
2. **`config/initializers/revision.rb`** for the git SHA, fed by a
   `--build-arg GIT_SHA`.
3. **CI triggers on that file changing** and creates the tag itself.

shopo is the one to fix first: its file is SemVer and its tags are CalVer, so it
already has the two disagreeing about what a release even is.
