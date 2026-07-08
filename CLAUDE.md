# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

This repo is the **canonical shared macOS CI/CD workflow** for three apps the user owns (filefillet, flowmoose, macpacker). It distributes builds to both Sparkle (Developer ID Direct) and the Mac App Store / TestFlight, with the goal of fire-and-forget release management. Each app repo has tiny per-app shell workflows that call into the orchestrators here via `uses: LeanBytes/workflows-macos/.github/workflows/<orchestrator>.yml@<tag>`.

**FlowMoose is the leading edge** — new workflow patterns are proven there first, then ported to filefillet and macpacker by updating each app's per-app shell to the new `@<tag>` and adjusting their inputs.

Layout: `.github/workflows/_build-{direct,app-store}.yml` are the internal callees; `.github/workflows/distribute-{pr,beta,release}.yml` are the orchestrators (plus `distribute-alpha.yml`, a manual private/invite-build orchestrator — see Shared workflow architecture); `.github/scripts/` holds `products.py` (the discovery/beta/release brain) plus helpers (`changelog-from-json.sh`, `update-appcast.sh`, …); each app repo carries one `Config/products/<id>.json` per product (identity + inline changelog); `examples/per-app/` has the trigger-only shell templates + `Config/products` samples; `tests/` holds the offline `products.py` suite. The actual filefillet / flowmoose / macpacker source trees live in their own repos.

## The three apps

All three now share the canonical pipeline. The single source of truth for versioning is each product's **`Config/products/<id>.json`** (build identity + inline changelog), plus git tags as ship-moment markers. The remaining differences are scope, not pipeline:

| App | Distribution channels | Notes |
|---|---|---|
| **flowmoose** (leading edge) | Direct (Sparkle, **stable + beta** channels) | Uses **Tuist** to generate the Xcode project. Caches Whisper `ggml-base.bin`. Can run on a self-hosted runner (`agent-alex`). Beta snapshots publish to the Sparkle beta channel. |
| **filefillet** | Direct (Sparkle, single channel) **and** App Store | Both channels. |
| **macpacker** (extra surface area) | Direct (Sparkle) **and** App Store (TestFlight) | Has Finder + Quick Look extensions — three provisioning profiles, three bundle IDs. Localization across many languages is on the roadmap but not started. |

## Versioning model (current — as of v0.4.0)

Each product's **`Config/products/<id>.json`** carries its own inline `changelog` (today's Changelog.json schema under a `changelog` key) — the single source of truth for **that product's** next-to-ship version + release notes. Git tags mark ship moments. The **primary** product (the one that omits `id`) uses **bare `vX.Y.Z`** tags; every other product is **`<id>-vX.Y.Z`** (the prefix is a git/CI identifier only — never the app's marketing version). At most one product per repo may omit `id`:

- `changelog.versions[0].version` = the in-progress version that product is building toward.
- Git tag `<id>-vX.Y.Z` = the stable release of that product's `X.Y.Z`. Pushing it triggers the release flow; CI validates it matches the product's `changelog.versions[0].version`.
- Git tag `<id>-vX.Y.Z-beta.N` = the Nth beta of that product's in-progress `X.Y.Z`. Auto-pushed **per product** by `distribute-beta.yml`.

**Marketing version per channel** (unchanged): Direct/Sparkle = `<ver>-beta.<N>` for betas, bare `<ver>` for releases; App Store/TestFlight = bare `<ver>` always (Apple's iTMS rejects non-`N.N.N` `CFBundleShortVersionString`).

**Gate (changelog-driven, per product):** on push→main a product cuts a beta only when its version is unreleased AND its own file changed since its last beta (see the Multi-product model section). No cross-product coupling — editing one product's changelog never cuts another's beta, and a released (idle) product is skipped, not blocked.

## Multi-product model (v0.4.0 — breaking)

As of **v0.4.0** a repo describes each product it ships as a self-contained **`Config/products/<id>.json`** file: build identity (`scheme`, `product-name`, `bundle-id`, `scheme-store` + store bundle ids, extension toggles + ids, per-channel `build-*`/`distribute-*` toggles, `devid-profile-secret`/`store-profile-secret`, `s3-subpath`, `appcast-filename`/`appcast-seed-path`, `platform`) **plus a mandatory inline `changelog`** (today's Changelog.json schema, verbatim, under a `changelog` key). The orchestrators **discover** products by globbing that dir; per-app shells are **trigger-only** (no `products` input). A single-product app has one file; FileFillet ships two (`base.json` + `pro.json`). **Proven end-to-end live in `LeanBytes/workflows-test`** (PR fan-out, per-product betas, release, idle-after-release, resume).

- **Every product is INDEPENDENT.** Its version = its own `changelog.versions[0].version`; its release tag = **`<id>-v<version>`** (e.g. `pro-v1.4.0`) — **except the primary product, which omits `id` and uses bare `v<version>`** (e.g. `v2.13.0`; ≤1 primary per repo, `products.py` enforces it, and a non-empty `id` must match its filename). Betas mirror the tag; its GH Release / S3 subpath / Sparkle appcast are its own. No shared changelog, no lockstep. **Two products at the same `s3-subpath`** (e.g. base + pro both at root) must set distinct `appcast-filename` **and** `changelog-filename` (default `Changelog.json`) so their published files don't collide.
- **Beta is CHANGELOG-DRIVEN.** On push→main, `products.py plan-beta` cuts a product's next beta **iff** (a) its version isn't released (no `<id>-v<ver>` tag) **and** (b) its own file changed since its last beta (`git diff <id>-v<ver>-beta.<last>..HEAD -- Config/products/<id>.json`). So editing only one product's changelog betas only that product; an idle product (released version) never rides another's betas.
- **The brain is `.github/scripts/products.py`**: `discover` (PR fan-out), `plan-beta` (changelog-driven cutting set), `plan-release` (parse `<id>-v*` tag → scoped product). Pure stdlib, offline-testable via injected `GIT_TAGS`/`CHANGED_PRODUCTS` — see `tests/run.sh` + `tests/fixtures/**` (and `selftest.yml` runs both on PRs to this repo). `changelog-from-json.sh` auto-descends into a product file's `.changelog`.
- **Changelog → S3 stays website-compatible.** Release publishes only the product's `.changelog`, extracted as `Changelog.json` (schema-identical to the old file), at the product's `s3-subpath` — build identity never goes public. Base at the S3 root (shipped 2.x apps look there); others under their subpath.
- **Identity left repo Variables.** The retired `SCHEME_NAME`/`SCHEME_NAME_STORE`/`PRODUCT_NAME`/`BUNDLE_ID*` are gone (now in the product files). Only infra stays in Variables (`S3_DISTRIBUTION_PATH`, `S3_DOWNLOAD_URL`, Jira). `build-direct.sh` is unchanged (env-driven; only where the env comes from changed).
- **Per-product provisioning profiles.** Certs/keychain/ASC/Sparkle keys are team-shared; a product names its profile secret via `devid-profile-secret`/`store-profile-secret` and the matrix leg selects it (`secrets[matrix.product.<key>]`), falling back to the shared `PROV_PROF_DEVID_BASE64`/`PROV_PROF_STORE_BASE64`.
- **Load-bearing GHA constraints** (encoded in the orchestrators): a job `if:` can't read `matrix` → `prepare` emits `direct-products`/`store-products` subset arrays + `has-*` booleans; an empty matrix throws → gate each build job on the presence boolean; `matrix.*` is illegal in `uses:`. Discovery-by-glob is fork-PR safe (files ship with the checkout). The publish loops read a **`\x1f`-delimited (NOT tab)** product table — tab is IFS-whitespace and collapses empty fields.
- **iOS build leg deferred (seam only).** `platform: ios` products are excluded from the mac build subsets; a future `_build-ios.yml` consumes an `ios-products` array `products.py` already knows how to emit.

## Roadmap (remaining work)

1. **macpacker localization + App Store**: add a CI step that translates strings into the app's supported languages and uploads the translated build to the App Store. Not started.

2. **iOS App Store build leg (`_build-ios.yml`) — NOT built.** The per-product independent model (v0.4.0, above) already has the seam: `platform: macos|ios` gates the mac build subsets so an iOS product never reaches the mac callees, and `products.py` can emit an `ios-products` array. When a FlowMoose **iOS + CarPlay** companion becomes real, add `_build-ios.yml` (iOS archive `-destination generic/platform=iOS` → export `method=app-store` → `.ipa` → `altool --type ios`; **no** notarize/staple/DMG/Sparkle), a `build-ios` job over that subset array, and an `ios` branch in the publish altool step. CarPlay is just an entitlement in the provisioning profile — no extra CI. An App-Store-only product's release is notes-only (no downloadable asset). The v0.4.0 discovery/fan-out/per-product-secrets/S3-subpath plumbing carries over unchanged.

The user works **step-by-step** — prove a change on the leading-edge app (FlowMoose) first, then port to filefillet and macpacker. Don't propose a big-bang rewrite that touches all three at once.

## Shared workflow architecture

Internal callees (`workflow_call` only, never triggered directly; per-app shells must not call them directly either — go through the orchestrators):

- **`_build-direct.yml`** — inputs: `version`, `build-number`, `artifact-label`. The build/sign/notarize/package logic lives in **`.github/scripts/build-direct.sh`** (the single source of truth, also run locally — see Editing patterns). The workflow checks workflows-macos out into `.shared-ci/` at `github.job_workflow_sha` and runs ONE phase of that script per named step, so the Actions UI keeps per-step names/timings/pass-fail. Phases: checkout (with submodules) → resolve SwiftPM (or Tuist when `use-tuist`) → keychain + provisioning profile + ASC API key setup → `xcodebuild archive` → `xcodebuild -exportArchive` (Developer ID, manual signing) → `notarytool submit --wait` → `stapler staple` → pre-package verify → DMG + ZIP via `hdiutil` and `ditto` (the latter with `--norsrc --noextattr --noacl` to avoid `__MACOSX/._*` injection per v0.3.15) → post-package verify → upload as `direct-build` GH Actions artifact. Cleanup (deletes keychain, profiles, ASC key; restores the keychain search list — `if: always()`).
- **`_build-app-store.yml`** — same shape, but exports for App Store with `xcrun altool`-compatible signing, produces a `.pkg`.

Orchestrators (each app's per-app shell calls one of these per trigger):

- **`distribute-pr.yml`** — fired on `pull_request: [opened, synchronize]`. A `discover` job runs `products.py discover` (validates every `Config/products/<id>.json`, including its mandatory inline changelog) and emits the product list; a matrix `verify` job **compiles every product** unsigned — fork-PR safe (files ship with the checkout, unlike `vars`/`secrets`). Optional `run-tests` swaps compile for the `_test.yml` gate. No signing/S3/PR comment.
- **`distribute-beta.yml`** — fired on `push: branches: [main]`. `prepare` runs `products.py plan-beta` → the **changelog-driven cutting set** (products whose version is unreleased AND whose own `Config/products/<id>.json` changed since their last beta). Build jobs matrix the cutting set (per-product marketing: `<ver>-beta.<N>` direct / bare `<ver>` store). `publish-beta` runs the `\x1f` per-product loop — altool → S3 → beta appcast — then **each product pushes its OWN `<id>-v<ver>-beta.N` tag + its OWN GH pre-release** (assets attached; idempotent tag-exists guard). Repo-wide `concurrency` serializes all per-product counters. Empty cutting set → build/publish skip (nothing ships).
- **`distribute-release.yml`** — fired on `push: tags: ['*-v*', '!*-v*-beta.*', '!*-v*-alpha.*']`. `prepare` runs `products.py plan-release` — parses the `<id>-v<ver>` tag → the single target product, validates `ver` against **that product's** inline changelog, fails loudly on mismatch/unknown-id/bare-`v*`. Builds + publishes **just it**: DMG/ZIP + stable appcast + its `.changelog` extracted to `Changelog.json` at its `s3-subpath`, then a GH Release for the tag (fail-safe order — Release last).
- **`distribute-alpha.yml`** — **manual** (`workflow_dispatch`), against a feature branch, for a **private invite-only** build (added v0.3.48). Pass **`product-id`** → identity + base version come from `Config/products/<id>.json`; tag `<id>-v<base>-alpha.N`, uploaded to an **unlisted `alpha/<version>/` S3 prefix** — deliberately **off** the public machinery (no appcast, no `Changelog.json` write, no GH Release, no auto-update). Direct-only secrets. Repo-wide `concurrency` serializes the counter. The release shell's `!*-v*-alpha.*` exclusion keeps the alpha tag from firing a release. `workflow_dispatch` needs the shell on the default branch (button) *and* the target branch (run uses that ref's code).

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

Nine scripts. `products.py` is the **discovery/beta/release brain** (globs `Config/products/*.json`; subcommands `discover`/`plan-beta`/`plan-release`; pure stdlib, offline-tested via `tests/run.sh` — see the Multi-product model section). The eight below are the build/test/changelog/jira helpers: `build-direct.sh` is the Direct build core (run by CI + `scripts/build-local.sh`); `run-tests.sh` is the test core; two consume a product's inline `.changelog`; `jira_client.py` is the shared Jira helper; the rest back the `memory-watch.yml` / `_test.yml` workflows:

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

- **Signing**: `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_PASSWORD`, `KEYCHAIN_PASSWORD`, `PROV_PROF_DEVID_BASE64` (+ `_FINDER_BASE64`, `_QL_BASE64` for macpacker direct; `PROV_PROF_STORE_*` for macpacker store). **Per-product profiles (v0.4.0):** a multi-product repo adds one profile secret per extra product (e.g. `PROV_PROF_DEVID_PRO_BASE64`, `PROV_PROF_STORE_PRO_BASE64`) and names it in that product's `devid-profile-secret`/`store-profile-secret`; certs/keychain/ASC/Sparkle stay shared.
- **Apple**: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_BASE64`.
- **Sparkle**: `SPARKLE_ED_PRIVATE_KEY` (EdDSA private key piped to `generate_appcast --ed-key-file -`).
- **AWS**: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (region hardcoded to `eu-central-1`).
- **Vars** (v0.4.0 — **infra only**): `S3_DISTRIBUTION_PATH`, `S3_DOWNLOAD_URL`. All product-identity Variables (`SCHEME_NAME`, `SCHEME_NAME_STORE`, `PRODUCT_NAME`, `BUNDLE_ID`(`_STORE`), `BUNDLE_ID_FINDER`/`BUNDLE_ID_QUICKLOOK`(`_STORE`)) are **retired** — that identity now lives in each **`Config/products/<id>.json`** (`scheme`, `scheme-store`, `product-name`, `bundle-id`, `bundle-id-store`, `bundle-id-finder`(`-store`), `bundle-id-quicklook`(`-store`)), discovered by the orchestrators. The `bundle-id-store` etc. keys keep the v0.3.38 store→direct fallback (an empty store id defaults to the Direct one), now resolved in `_build-app-store.yml` from inputs. **Test/Jira vars** (only when `run-tests` / `file-jira-on-failure`): `JIRA_BASE_URL`, `JIRA_PROJECT_KEY`, `JIRA_USER_EMAIL`, optional `JIRA_ISSUE_TYPE` + `JIRA_BOARD_ID` (the board whose **active sprint** receives auto-filed tickets), and the `JIRA_API_TOKEN` secret.

(Jira enrichment was removed in v0.3.17 when the notes source moved to `Config/Changelog.json`. The Jira secrets/vars on the caller repos are now dead config and can be deleted on the user's schedule.)

## Editing patterns

- **All workflow logic lives here in `workflows-macos`; per-app shells only declare triggers and inputs.** When iterating on logic, edit `_build-*.yml` / `distribute-*.yml` in this repo and bump the tag. Don't fork logic into per-app shells.
- **The Direct build's shell logic lives in `.github/scripts/build-direct.sh`, not inline in `_build-direct.yml`** (which now just calls it one phase per step). Edit the script — it's the single source of truth and is testable on a Mac via `scripts/build-local.sh` without a commit or CI run. Keep the script and `_build-direct.yml`'s step list in lockstep (one phase ↔ one step).
- **Move incrementally per app.** Prove a workflow change end-to-end on the leading-edge app (FlowMoose), then port the per-app shell to filefillet and macpacker. The user has explicitly asked for step-by-step — don't roll a single change across all three apps in one pass unless it's a trivially shared snippet.
- **When bumping the shared workflow's tag, also bump the `@v<tag>` callouts inside the shared workflows AND in `examples/per-app/`.** This is the convention enforced by every release commit message ("Cross-callouts and example shells bumped to @v0.4.2").
