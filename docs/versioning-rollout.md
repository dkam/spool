# Versioning rollout brief

**Paste this into a Claude session working in the target repo, or point at it:
`../spool/docs/versioning-rollout.md`.**

You are standardising how a Rails app knows its own version and how its
container image gets built and released. Six sibling repos currently use four
different schemes; this brings one of them into line. Spool is the reference
implementation — read `../spool/docs/deploy.md`, `../spool/config/version.rb`,
`../spool/config/initializers/revision.rb` and
`../spool/.github/workflows/build.yml` before starting.

Work on a branch. Do not commit unless asked.

---

## What we want

**Two numbers, deliberately separate.**

| | Lives in | Set by | Answers |
| --- | --- | --- | --- |
| **version** | `config/version.rb` → `<App>::VERSION` | a human, by hand | *which release is this?* |
| **revision** | `config.x.revision` | the build, from `--build-arg GIT_SHA` | *is what I built actually running?* |

The revision is precise, automatic and meaningless to read. The version survives
a rebuild of identical code, goes in a changelog, and is what you say out loud.
Conflating them loses one of the two. Most apps have only the revision and then
have no way to name a release.

**Bumping `config/version.rb` on main is what cuts a release.** CI triggers on
that path, builds a multi-arch image, publishes it to ghcr.io, *and creates the
matching git tag*. There is no `git tag` step for a human to forget.

## Why not tag-driven

Three options exist. Only one has a single source of truth.

1. **Tag-driven** — `git tag v1.2.0`, CI fires on `tags: v*`. The version exists
   only in git, so the running app cannot report its own version without being
   told, and the release is not reviewable — a tag has no diff.
2. **File-driven** ← *this is what we want.* The constant is the truth. The bump
   is an ordinary commit you can review, revert and blame, and the app reads it
   at runtime with no git present.
3. **SHA-only** — build every push. Honest, but nothing has a human name, so
   "which release broke it" has no answer.

The failure mode of (2), which is why the tag job is mandatory and not optional:
**splat's `config/version.rb` reads 1.15.0 while its newest git tag is v1.7.8.**
Eight versions apart. The image tags kept moving and the git tags stopped,
because tagging was a separate manual step and manual steps stop happening.
Make the tag a *consequence* of the release, not a chore beside it.

---

## What to build

### 1. `config/version.rb`

```ruby
# frozen_string_literal: true

module <AppModule>
  VERSION = "X.Y.Z"
end
```

Comment it with the version-vs-revision distinction above.

- `config/`, **not** `lib/` — it must be requirable without booting Rails:
  `ruby -e "require './config/version'; puts <AppModule>::VERSION"`
- Require it from the top of `config/application.rb`, before `require "rails"`.
- **Use the app's real module name** (see the table below — two of them are not
  what you'd guess).
- **Derive the starting version from the highest existing git tag**, don't
  invent one. `git tag --list --sort=-v:refname | head -1`. Never go backwards.
- If a version file already exists somewhere else, **move it** to
  `config/version.rb` and update every reference; don't leave two.

### 2. `config/initializers/revision.rb`

Copy Spool's verbatim, adjusting nothing. It reads a `VERSION` file written at
image build time, falls back to `git rev-parse --short HEAD` **in development
only** (a deployed container must not shell out on boot), then to `ENV["GIT_SHA"]`,
then `"unknown"`.

### 3. Dockerfile

Add, in the **build** stage, *after* `COPY . .`:

```dockerfile
ARG GIT_SHA=unknown
RUN echo "${GIT_SHA}" > VERSION
```

The placement matters: an `ARG` is only in scope for the stage that declares it.
Put it before the `FROM` and `--build-arg` is silently ignored, which fails as
every deploy reporting `unknown` and nobody noticing for a month.

Also add `LABEL org.opencontainers.image.source=https://github.com/dkam/<repo>`
if absent, so the package links back to the repo on GitHub.

### 4. `.github/workflows/build.yml`

Copy Spool's. It has four jobs: `prepare` (read the constant, decide whether
this moves `:latest`), `build` (matrix over amd64 + arm64, **native runners, no
QEMU**, push by digest), `merge` (stitch one manifest), `tag` (create the git
tag and GitHub Release).

- Trigger: `push: branches: [main], paths: [config/version.rb]` plus
  `workflow_dispatch`.
- Pass `build-args: GIT_SHA=${{ github.sha }}`.
- A pre-release — any version containing a hyphen, e.g. `0.2.0-dev` — publishes
  `:v0.2.0-dev`, does **not** move `:latest`, and creates **no git tag**.
- The `tag` job needs `permissions: contents: write` and must be idempotent
  (check `git ls-remote --tags` and `gh release view` first), so re-running the
  workflow on an unchanged version is a no-op rather than a failure.

**If the repo already has a `build.yml` (splat, clinch): add only the `tag`
job.** Don't rewrite what works.

### 5. `bin/build`, if present

Every repo has one for local multi-arch builds. Make it read the same constant
and pass `--build-arg GIT_SHA=$(git rev-parse HEAD)`. Splat's already reads the
version and enforces "releases only from main" — keep that.

### 6. CI: prove the image builds on every PR

Add a `build-image` job to `ci.yml`: amd64 only, `push: false`, with GHA cache.
It is a smoke test, not a publish.

This is not optional garnish. Without it the Dockerfile is first exercised *by
the release itself*, which is the worst possible moment — see below.

---

## Expect the image build to be broken

Spool could not be containerised **at all**, and nothing in a green test suite
showed it, because **nothing else ever boots in `RAILS_ENV=production`**.
`assets:precompile` does exactly that, with no runtime configuration present.
Three separate faults, all likely present in any app grown from the same Rails
template:

1. **`config/application.rb` reading `ENV["SECRET_KEY_BASE"]` directly and
   raising.** Rails sets `SECRET_KEY_BASE_DUMMY=1` for precisely this case;
   reading the environment bypasses the mechanism provided to solve it. Fix:
   `if Rails.env.production? && ENV["SECRET_KEY_BASE_DUMMY"].blank?`
2. **`config/environments/production.rb` configuring a gem that is no longer in
   the Gemfile** — for Spool, `config.solid_queue.connects_to`, left over after
   moving to tuber. `NoMethodError` at boot. Check `solid_queue`, `active_storage`,
   `action_mailbox`, `action_text` against the Gemfile.
3. **A boot-time guard that refuses to start without runtime config** — Spool's
   initializer refused to boot without OIDC. Correct at runtime, fatal during a
   build.

**The rule that resolves all three: a check that guards *serving traffic* must
not fire while *compiling assets*.** `SECRET_KEY_BASE_DUMMY` is the signal Rails
itself sets to mean "this boot will never serve a request" — guard on that,
not on a task name.

Keep the exemption narrow, and pin it with a test — see
`../spool/test/config/build_boot_test.rb`. Then **verify the guard still bites**
by running the built image without the config and confirming it refuses. Do not
reason about this; run it.

While you're in the Dockerfile, check for `libvips` in a repo with no Active
Storage and no `image_processing` gem. It's ~40MB of nothing.

---

## Per-repo facts

Surveyed 2026-08-12. **Check these are still true before relying on them.**

| Repo | App module | Highest tag | Version file today | build.yml | Work |
| --- | --- | --- | --- | --- | --- |
| splat | `Splat` | `v1.7.8` | `config/version.rb` = **1.15.0** | yes, ghcr | **add the `tag` job only.** Tags are 8 versions stale — the first run will tag v1.15.0, which is correct and worth expecting |
| clinch | `Clinch` | `v0.16.2` | `config/initializers/version.rb` = 0.17.1 | yes, ghcr | add `tag` job; **move** the file out of `initializers/` into `config/version.rb` |
| booko | `Booko` | `v10.20` | none | none | full rollout. Start at `10.21.0` — the `vMAJOR.MINOR` tags need a patch component to be SemVer |
| covers | **`Tbdb`** | marker tags only | none | none | full rollout. No release tags at all; start at `0.1.0`. **Module is `Tbdb`, not `Covers`** |
| shopo | **`ShopoSa`** | `2024.01` | `config/version.rb` = 0.6.2, `module Shopo` | none | full rollout. **Fix first** — file is SemVer and tags are CalVer, so they already disagree about what a release *is*. Also the module in version.rb (`Shopo`) doesn't match the app (`ShopoSa`); pick one |
| gr | `Gr` | `2025.01` | none | none | full rollout, CalVer → SemVer. Start at `0.1.0` unless there's a better claim |

**CalVer → SemVer (shopo, gr):** don't rewrite history or delete old tags. Leave
the CalVer tags where they are and start a `v`-prefixed SemVer series alongside.
Note the changeover in the repo's docs.

## Definition of done

- [ ] `ruby -e "require './config/version'; puts <App>::VERSION"` prints, no Rails
- [ ] `bin/rails runner 'puts Rails.application.config.x.revision'` prints a SHA in dev
- [ ] `docker build --build-arg GIT_SHA=test -t <app>:citest .` **succeeds**
- [ ] `docker run --rm --entrypoint sh <app>:citest -c 'cat VERSION'` → `test`
- [ ] the image **boots** in production with real config and reports both numbers
- [ ] any boot-time guards still **refuse** a genuinely misconfigured production boot
- [ ] existing test suite green, linter clean
- [ ] the repo's own docs record the scheme and the release procedure

Report what you found, especially any of the three build-time faults — they're
worth knowing about across the fleet, not just fixing locally.
