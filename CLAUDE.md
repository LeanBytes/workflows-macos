# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

This repo is the **canonical shared macOS CI/CD workflow** for three apps the user owns (filefillet, flowmoose, macpacker). It distributes builds to both Sparkle (Developer ID Direct) and the Mac App Store / TestFlight, with the goal of fire-and-forget release management. Each app repo has tiny per-app shell workflows that call into the orchestrators here via `uses: LeanBytes/workflows-macos/.github/workflows/<orchestrator>.yml@<tag>`.

**FlowMoose is the leading edge** — new workflow patterns are proven there first, then ported to filefillet and macpacker by updating each app's per-app shell to the new `@<tag>` and adjusting their inputs.

Layout: `.github/workflows/_build-{direct,app-store}.yml` are the internal callees; `.github/workflows/distribute-{pr,beta,release}.yml` are the orchestrators (plus `distribute-alpha.yml`, a manual private/invite-build orchestrator — see Shared workflow architecture); `.github/scripts/` has two helpers (`changelog-from-json.sh`, `update-appcast.sh`); `examples/per-app/` has the per-app shell templates. The actual filefillet / flowmoose / macpacker source trees live in their own repos.

## The three apps

All three now share the canonical pipeline. The single source of truth for versioning is `Config/Changelog.json` in each app repo, plus git tags as ship-moment markers. The remaining differences are scope, not pipeline:

| App | Distribution channels | Notes |
|---|---|---|
| **flowmoose** (leading edge) | Direct (Sparkle, **stable + beta** channels) | Uses **Tuist** to generate the Xcode project. Caches Whisper `ggml-base.bin`. Can run on a self-hosted runner (`agent-alex`). Beta snapshots publish to the Sparkle beta channel. |
| **filefillet** | Direct (Sparkle, single channel) **and** App Store | Both channels. |
| **macpacker** (extra surface area) | Direct (Sparkle) **and** App Store (TestFlight) | Has Finder + Quick Look extensions — three provisioning profiles, three bundle IDs. Localization across many languages is on the roadmap but not started. |

## Versioning model (current — as of v0.3.18)

`Config/Changelog.json` in each caller repo is the single source of truth for the next-to-ship version and the customer-facing release notes. Git tags mark ship moments:

- `versions[0].version` = the in-progress version being built toward. Beta builds read this.
- Git tag `vX.Y.Z` = the stable release of `X.Y.Z`. Pushing this tag triggers the release flow; CI validates the tag matches `versions[0].version` in the tagged commit's Changelog.json.
- Git tag `vX.Y.Z-beta.N` = the Nth beta cut for in-progress `X.Y.Z`. Auto-pushed by `distribute-beta.yml` on every PR merge.

**Marketing version per channel:**
- Direct (Sparkle): `<next>-beta.<N>` for betas (e.g. `2.12.0-beta.4`), bare `<next>` for releases.
- App Store / TestFlight: bare `<next>` always — Apple's iTMS rejects non-`N.N.N` strings in `CFBundleShortVersionString`.

**Safeguard (the gate):** if `versions[0].version` already has a corresponding `v<X.Y.Z>` tag, beta builds refuse to publish. The check is surfaced as a PR check in `distribute-pr.yml`'s `prepare` step (primary feedback surface for the developer) and repeated in `distribute-beta.yml` as a defensive backstop. Commits and merges are never blocked by this — only the auto-publish work refuses to run against stale state. Fix: prepend a new entry to `versions[]` in `Config/Changelog.json`.

## Roadmap (remaining work)

1. **macpacker localization + App Store**: add a CI step that translates strings into the app's supported languages and uploads the translated build to the App Store. Not started.

The user works **step-by-step** — prove a change on the leading-edge app (FlowMoose) first, then port to filefillet and macpacker. Don't propose a big-bang rewrite that touches all three at once.

## Shared workflow architecture

Internal callees (`workflow_call` only, never triggered directly; per-app shells must not call them directly either — go through the orchestrators):

- **`_build-direct.yml`** — inputs: `version`, `build-number`, `artifact-label`. The build/sign/notarize/package logic lives in **`.github/scripts/build-direct.sh`** (the single source of truth, also run locally — see Editing patterns). The workflow checks workflows-macos out into `.shared-ci/` at `github.job_workflow_sha` and runs ONE phase of that script per named step, so the Actions UI keeps per-step names/timings/pass-fail. Phases: checkout (with submodules) → resolve SwiftPM (or Tuist when `use-tuist`) → keychain + provisioning profile + ASC API key setup → `xcodebuild archive` → `xcodebuild -exportArchive` (Developer ID, manual signing) → `notarytool submit --wait` → `stapler staple` → pre-package verify → DMG + ZIP via `hdiutil` and `ditto` (the latter with `--norsrc --noextattr --noacl` to avoid `__MACOSX/._*` injection per v0.3.15) → post-package verify → upload as `direct-build` GH Actions artifact. Cleanup (deletes keychain, profiles, ASC key; restores the keychain search list — `if: always()`).
- **`_build-app-store.yml`** — same shape, but exports for App Store with `xcrun altool`-compatible signing, produces a `.pkg`.

Orchestrators (each app's per-app shell calls one of these per trigger):

- **`distribute-pr.yml`** — fired by the caller's shell on `pull_request: [opened, synchronize]`. `prepare` job reads `Config/Changelog.json`, validates `versions[0].version` doesn't already have a release tag (the **safeguard PR check**), computes marketing version `<next>-pr.<PR#>.<buildnumber>`, builds direct, uploads to S3, comments on the PR with download links.
- **`distribute-beta.yml`** — fired by the caller's shell on `pull_request: closed` + `merged == true`. `prepare` reads Changelog.json, repeats the safeguard, counts existing `v<next>-beta.*` tags, picks the next number. Two channel-specific marketing versions are computed: direct = `<next>-beta.<N>`, App Store = `<next>` (Apple rejects suffixes). Builds, uploads, updates the Sparkle beta channel (when enabled), pushes `v<next>-beta.<N>` tag, creates a GH pre-release. A repo-level `concurrency` group serializes runs so the beta counter never races.
- **`distribute-release.yml`** — fired by the caller's shell on `push: tags: ['v*.*.*']` (with `!v*-beta.*` and `!v*-alpha.*` exclusions to ignore auto-pushed beta tags and manual alpha tags). `prepare` validates the pushed tag matches `Config/Changelog.json` `versions[0].version` and fails loudly on mismatch. Marketing version = the bare semver from the tag for both direct and App Store. Builds, uploads, updates the stable appcast, creates the GH Release last (strict fail-safe order).
- **`distribute-alpha.yml`** — fired **manually** (`workflow_dispatch`), run against a feature branch (e.g. a `3.0` branch) to cut a **private, invite-only** build (added v0.3.48). `prepare` derives the base version from the branch's `Changelog.json` `versions[0]` (**read-only**) or a `version-base` input, counts existing `v<base>-alpha.*` tags for the next `N`, marketing = `<base>-alpha.<N>` (e.g. `3.0.0-alpha.1`). Reuses `_build-direct.yml` **verbatim** (same signed/notarized/stapled DMG+ZIP a release would produce), uploads to an **unlisted `alpha/<version>/` S3 prefix**, pushes a `v<base>-alpha.<N>` tag (the counter + durable record, mirroring the beta counter), and writes the handable download URL to `$GITHUB_STEP_SUMMARY`. Deliberately **off** the public machinery: no appcast, no `Changelog.json` write, no GH Release, no auto-update. Direct-only secrets (no Sparkle key, no App Store certs). Repo-level `concurrency` serializes the counter. **The per-app release shell MUST exclude `v*-alpha.*`** or the alpha tag fires the release flow. `workflow_dispatch` needs the shell on the default branch (button) *and* the target branch (run uses that ref's code).

Standalone reusable (not a release flow):

- **`memory-watch.yml`** — `workflow_call` that builds an app **unsigned**, runs it for hours, and samples RSS for leaks via `memory_watch.py`. A detected leak is a **successful** run (files a Jira ticket when `file-jira-on-leak`); only an infra/watch error (build/launch/watcher failure) fails the job. The per-app shell owns the cron; a per-commit cache gate watches each `main` commit once. First used by TailBeat.
- **`_test.yml`** — `workflow_call` that runs an app's Swift tests **unsigned** via `run-tests.sh` (`test-runner`: `swift` for the core package + coverage, `xcodebuild` for the app scheme, or `both`). Results go to `$GITHUB_STEP_SUMMARY` + an artifact. Called three ways: by `distribute-pr.yml` (red PR check, no ticket), by `distribute-beta.yml` as a **gate** (a failing test makes `build-direct`/`build-app-store`/`publish-beta` skip via `needs: [prepare, test]` + `needs.test.result != 'failure'`, so no beta ships, and files a ticket), and directly by a per-app nightly shell. Conventional semantics: test failure = **red** (+ ticket when `file-jira-on-failure`). Despite the `_` prefix it's caller-facing (nightly shells call it).

Conventions:

- **Build number** is `date -u +%y%m%d%H%M%S` — UTC timestamp, strictly monotonic, used as `CFBundleVersion` / `CURRENT_PROJECT_VERSION`. Every build path uses this.
- **Marketing version** is the `version` input passed into `_build-direct.yml` / `_build-app-store.yml` and injected at archive time via `xcodebuild MARKETING_VERSION=…`. The orchestrators compute and pass channel-specific values (see above).
- **Signing**: Developer ID p12 imported into an ephemeral `build.keychain`; provisioning profile name is read from the decoded `.provisionprofile` via `security cms -D | plutil -extract Name raw -`.
- **Notarization**: ASC API key (`AuthKey_<id>.p8`) under `~/.appstoreconnect/private_keys/`, `notarytool submit --wait`. Rejection log is fetched and printed on failure.
- **Artifact distribution**: S3 bucket in `eu-central-1`. `${{ vars.S3_DISTRIBUTION_PATH }}` is the upload target; `${{ vars.S3_DOWNLOAD_URL }}` is the public base URL embedded in PR comments. (macpacker stores `S3_DISTRIBUTION_PATH` as a **secret**, not a var — drift worth normalizing.)
- **Runner**: hosted `macos-26` everywhere by default. `_build-direct.yml` accepts a `runs-on` input (JSON-encoded label or label array); FlowMoose's beta shell passes `["self-hosted","agent-alex"]`.
- **LFS**: every build workflow takes an `lfs` boolean input (default `false`), plumbed to `actions/checkout` on the **build-feeding** checkouts only (`_build-direct`/`_build-app-store`/`_test` test job/`distribute-pr` verify/`memory-watch` watch; the orchestrators pass it through to their callees). `prepare`/`publish`/`gate` checkouts stay plain — they only read `Changelog.json` or publish artifacts, so they never pull the LFS payload. FlowMoose sets `lfs: true` (its Whisper `ggml-base.bin` is LFS-tracked); the other apps leave it off (a no-op).

## Scripts in `.github/scripts/`

Eight scripts. `build-direct.sh` is the Direct build core (run by CI + `scripts/build-local.sh`); `run-tests.sh` is the test core; two consume `Config/Changelog.json`; `jira_client.py` is the shared Jira helper; the rest back the `memory-watch.yml` / `_test.yml` workflows:

1. **`build-direct.sh`** — the Developer ID Direct build core: one bash function per phase (resolve → keychain → archive → export → notarize → staple → verify → DMG/ZIP → verify → cleanup) plus a dispatcher. `build-direct.sh <phase>` for CI's per-step calls; `build-direct.sh all` for a local one-shot. Single source of truth — `_build-direct.yml` runs it phase-by-phase, `scripts/build-local.sh` runs `all` on a Mac. Env-driven with no cross-phase in-memory state — paths are re-derived each phase, and profile Names are captured pre-archive in `signing` and persisted to `WORK_DIR` for `export` (CI runs each phase as a separate process, and `xcodebuild archive` renames the profile files, so re-reading them later fails). MUST stay in lockstep with `_build-direct.yml`'s step list; the script's header banner lists the load-bearing invariants (the `ditto --norsrc --noextattr --noacl` flags, `method=developer-id`, the `spctl`/`codesign --deep --strict`/`stapler validate` set).
2. **`changelog-from-json.sh`** — renders Markdown release notes for the appcast `<description>` and GH Release body. Takes `CHANGELOG_PATH` + `VERSION` (exact marketing version, or the `NEXT` sentinel for `versions[0]`). Bucketing: `feat → New Features`, `fix → Bug Fixes`, `core → Improvements`. `chore` and any unrecognized type are silently dropped. Items may also carry an optional `issues` **array of strings** (Jira keys and/or GitHub issues, e.g. `["MP-417", "#98"]`; one-element list for a single ticket, omit when none) — pure provenance, **ignored** by this script and the whole pipeline (and by the app's What's New view); it replaced the old numeric `pr` field, which was equally unused.
3. **`update-appcast.sh`** — `generate_appcast` doesn't emit `<description>`, so this script finds the matching `<item>` (by `sparkle:version` for betas — build number is the unique key — or `sparkle:shortVersionString` for stable releases) and injects a CDATA description. Then it trims to `APPCAST_MAX_ITEMS` (default 20). Trim and inject run in a single ElementTree pass; CDATA wrapping happens post-write as a text substitution so the trim doesn't dissolve the wrapper.
4. **`memory_watch.py`** — samples a running app's RSS (via `ps`) at intervals, applies a hard cap + a post-warmup slope-and-floor trend rule, and exits `0` healthy / `2` leak / `3` error (argparse/crash forced to 3 so it never masquerades as a leak). Pure stdlib. Backs `memory-watch.yml`, not the release flow.
5. **`create_jira_ticket.py`** — files a Jira issue from a `memory_watch.py` report when a leak is found (builds the summary/description; the create + sprint mechanics live in `jira_client.py`). `--dry-run`.
6. **`run-tests.sh`** — the test core: runs `swift test --enable-code-coverage` (core package — coverage % + optional `COVERAGE_MIN` gate) and/or unsigned `xcodebuild test` (app scheme) per `TEST_RUNNER` (`swift`|`xcodebuild`|`both`). Container auto-detect + tuist/swiftpm setup like the build core. Writes `test-report.json` + a `$GITHUB_STEP_SUMMARY` table; exit 0 = pass, non-zero = fail. Locally runnable.
7. **`jira_client.py`** — shared Jira helper imported by both ticket scripts: REST v2 create (Basic auth, plain-string description) **plus active-sprint placement** (resolve board → active sprint → add the issue; best-effort, warns on failure). CI-filed tickets land in the current active sprint, not the backlog.
8. **`create_test_ticket.py`** — files a Jira issue from `run-tests.sh`'s `test-report.json` (which runner/tests failed, coverage) via `jira_client.py`. `--dry-run`.

Versioning, beta-counting, and tag validation are all **inline** in the orchestrator workflows now — there is no `version-derive.sh` (deleted in v0.3.18). See the prepare-job steps in `distribute-{pr,beta,release}.yml` for the actual logic.

## Testing the scripts locally

`changelog-from-json.sh` and `update-appcast.sh` are pure data transforms — easy to exercise from the repo root with a hand-crafted fixture:

```bash
# changelog-from-json.sh
cat > /tmp/cl.json <<'JSON'
{"versions":[{"version":"2.12.0","items":[
  {"type":"feat","title":{"en":"New thing"}},
  {"type":"fix","title":{"en":"Broken thing"}}
]}]}
JSON
CHANGELOG_PATH=/tmp/cl.json VERSION=2.12.0 bash .github/scripts/changelog-from-json.sh
CHANGELOG_PATH=/tmp/cl.json VERSION=NEXT     bash .github/scripts/changelog-from-json.sh
```

The deleted Bash test suite for `version-derive.sh`, `generate-changelog.sh`, and `enrich-changelog-with-jira.sh` is gone with the scripts themselves.

## Required GitHub secrets and vars (across all three workflows)

Don't hardcode these — they're read from `secrets.*` and `vars.*` in every workflow:

- **Signing**: `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_PASSWORD`, `KEYCHAIN_PASSWORD`, `PROV_PROF_DEVID_BASE64` (+ `_FINDER_BASE64`, `_QL_BASE64` for macpacker direct; `PROV_PROF_STORE_*` for macpacker store).
- **Apple**: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_BASE64`.
- **Sparkle**: `SPARKLE_ED_PRIVATE_KEY` (EdDSA private key piped to `generate_appcast --ed-key-file -`).
- **AWS**: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (region hardcoded to `eu-central-1`).
- **Vars**: `SCHEME_NAME`, `BUNDLE_ID`, `PRODUCT_NAME`, `S3_DISTRIBUTION_PATH`, `S3_DOWNLOAD_URL`. macpacker also has `BUNDLE_ID_FINDER`, `BUNDLE_ID_QUICKLOOK`, `SCHEME_NAME_STORE`. **Optional App Store bundle-id overrides** (added in v0.3.38; each defaults to its Direct counterpart when unset): `BUNDLE_ID_STORE`, `BUNDLE_ID_FINDER_STORE`, `BUNDLE_ID_QUICKLOOK_STORE` — set only when an app's App Store bundle id differs from its Direct one. Used solely as the `provisioningProfiles` keys in `_build-app-store.yml`'s export (the store profile must match). **Test/Jira vars** (only when `run-tests` / `file-jira-on-failure`): `JIRA_BASE_URL`, `JIRA_PROJECT_KEY`, `JIRA_USER_EMAIL`, optional `JIRA_ISSUE_TYPE` + `JIRA_BOARD_ID` (the board whose **active sprint** receives auto-filed tickets), and the `JIRA_API_TOKEN` secret.

(Jira enrichment was removed in v0.3.17 when the notes source moved to `Config/Changelog.json`. The Jira secrets/vars on the caller repos are now dead config and can be deleted on the user's schedule.)

## Editing patterns

- **All workflow logic lives here in `workflows-macos`; per-app shells only declare triggers and inputs.** When iterating on logic, edit `_build-*.yml` / `distribute-*.yml` in this repo and bump the tag. Don't fork logic into per-app shells.
- **The Direct build's shell logic lives in `.github/scripts/build-direct.sh`, not inline in `_build-direct.yml`** (which now just calls it one phase per step). Edit the script — it's the single source of truth and is testable on a Mac via `scripts/build-local.sh` without a commit or CI run. Keep the script and `_build-direct.yml`'s step list in lockstep (one phase ↔ one step).
- **Move incrementally per app.** Prove a workflow change end-to-end on the leading-edge app (FlowMoose), then port the per-app shell to filefillet and macpacker. The user has explicitly asked for step-by-step — don't roll a single change across all three apps in one pass unless it's a trivially shared snippet.
- **When bumping the shared workflow's tag, also bump the `@v<tag>` callouts inside the shared workflows AND in `examples/per-app/`.** This is the convention enforced by every v0.3.x release commit message ("Cross-callouts and example shells bumped to @v0.3.X").
