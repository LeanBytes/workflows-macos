# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

This repo is the **alignment ground for one canonical macOS CI/CD workflow** that takes the user fully off CI tracking — fire-and-forget distribution to both Sparkle (external) and the Mac App Store. The `.github/` trees under `workflows/<app>/` are extracted copies from three real macOS apps (**filefillet**, **flowmoose**, **macpacker**) that the user owns; workflows are iterated here and propagated by hand back to the originating repos. Nothing in this directory is wired to a runner — no top-level `.github/workflows`, no source code, no Xcode project.

The three apps are at different points along the path to the canonical pattern, not three independent specimens. **FlowMoose is the leading edge** — most new patterns are tried there first. **filefillet** is the minimum viable version (single-channel Sparkle, no Jira, no beta). **macpacker** carries extra surface area the canonical pattern eventually has to absorb (App Store + Finder/Quick Look extensions today; localization across many languages still to come).

When working in this directory, treat each `workflows/<app>/.github/` subtree as if it were that app's repo root (e.g. `version-derive.sh` expects to be invoked from `workflows/flowmoose/`, where `git describe` runs against this repo's history if you actually execute it — which is usually wrong; the scripts are intended to be read or unit-tested, not run live).

## The three apps and how far along each one is

All three follow the same caller/callee workflow split but diverge in versioning, distribution channels, and changelog handling. Read this as "leading edge → minimum viable → extra surface area still to integrate" — the drift is the gap to close, not the steady state:

| App | Versioning source | Distribution channels | Notes |
|---|---|---|---|
| **flowmoose** (leading edge) | `git describe --tags --long` (LB-402); xcconfig only holds `0.0.0-dev` placeholder | Direct (Sparkle, **stable + beta** channels) | Most advanced. Python appcast script driven by `CHANGELOG.json`, with Jira enrichment. Uses **Tuist** to generate the Xcode project. Caches Whisper `ggml-base.bin`. Can run on a self-hosted runner (`agent-alex`). Snapshot builds are published to the beta appcast channel. |
| **filefillet** (minimum viable) | `Config/Version.xcconfig` → `MARKETING_VERSION` | Direct (Sparkle, single channel) | Simplest. AWK-based appcast script reads `CHANGELOG.md`, keeps 3 items, currently uploads to `appcast_test.xml`. |
| **macpacker** (extra surface area) | `Config/Version.xcconfig` → `MARKETING_VERSION` | Direct (Sparkle) **and** App Store (TestFlight) | Has Finder + Quick Look extensions — three provisioning profiles, three bundle IDs. Extra `distribute-macos-store.yml` builds with the store scheme and uploads via `xcrun altool`. Localization across many languages is on the roadmap but not started. |

## Roadmap (incremental, in this order)

1. **Stabilize the changelog → appcast pipeline in FlowMoose, then unify the appcast script across apps.** Today `generate-changelog.sh` walks `git log` for `(#NN)`-suffixed squash-merges, with a fragile fallback for `pull_request: closed` events (the `PR_TITLE`/`PR_NUMBER` workaround in `generate-changelog.sh`). Planned replacement: switch the changelog **source** to **GitHub Releases auto-generated notes** — GH already produces the diff between two versions natively, which collapses most of the per-app divergence in `generate-changelog.sh` and `update-appcast.sh`.
2. **Propagate the unified workflow to filefillet and macpacker** once it's stable in FlowMoose.
3. **macpacker localization + App Store**: add a CI step that translates strings into the app's supported languages and uploads the translated build to the App Store. Not started.

The user works **step-by-step** — prove a change on the leading-edge app first, then port. Don't propose a big-bang rewrite that touches all three at once.

## Shared workflow architecture (all three apps)

Each app's `.github/workflows/` has the same caller/callee split:

- **`distribute-build.yml`** — `workflow_call` only, never triggered directly. Inputs: `version`, `build-number`, `artifact-label`. Does: checkout (with submodules) → resolve SwiftPM (or Tuist for flowmoose) → keychain + provisioning profile + ASC API key setup → `xcodebuild archive` → `xcodebuild -exportArchive` (Developer ID, manual signing) → `notarytool submit --wait` → `stapler staple` → DMG + ZIP via `hdiutil` and `ditto` → `aws s3 cp` to `eu-central-1` → cleanup (deletes keychain, profiles, ASC key — `if: always()`).
- **`distribute-pr.yml`** — `pull_request: [opened, synchronize]`. `prepare` (ubuntu) computes version/build/artifact-label → calls `distribute-build.yml` → `comment` posts a Markdown table of DMG/ZIP S3 links on the PR. Artifact label format: `v<version>-beta-<buildnumber>-pr<N>`.
- **`distribute-snapshot.yml`** — `pull_request: [closed]` on `main`, gated by `merged == true`. Same as PR flow but artifact label is `v<version>-beta-<buildnumber>` (no PR suffix). flowmoose additionally publishes to the **beta** Sparkle channel here.
- **`distribute-release.yml`** — `push: tags: ['v*.*.*']`. Builds, then `update-appcast` job downloads the latest Sparkle, runs `generate_appcast --ed-key-file -`, injects release notes via `update-appcast.sh`, and uploads `appcast.xml` (+ `CHANGELOG.json` for flowmoose) to S3.

Conventions that hold across all three:

- **Build number** is `date -u +%y%m%d%H%M%S` — UTC timestamp, strictly monotonic, used as `CFBundleVersion` / `CURRENT_PROJECT_VERSION`.
- **Marketing version** is injected at archive time via `xcodebuild MARKETING_VERSION=…` (and for filefillet/macpacker, also pre-applied with `agvtool`).
- **Signing**: Developer ID p12 imported into an ephemeral `build.keychain`; provisioning profile name is read from the decoded `.provisionprofile` via `security cms -D | plutil -extract Name raw -`.
- **Notarization**: ASC API key (`AuthKey_<id>.p8`) under `~/.appstoreconnect/private_keys/`, `notarytool submit --wait`. flowmoose additionally captures and prints the rejection log on failure.
- **Artifact distribution**: S3 bucket in `eu-central-1`. `${{ vars.S3_DISTRIBUTION_PATH }}` is the upload target; `${{ vars.S3_DOWNLOAD_URL }}` is the public base URL embedded in PR comments. (macpacker stores `S3_DISTRIBUTION_PATH` as a **secret**, not a var — drift worth normalizing.)
- **Runner**: hosted `macos-26` everywhere by default. flowmoose's `distribute-build.yml` accepts a `runs-on` input (JSON-encoded label or label array) and its snapshot workflow passes `["self-hosted","agent-alex"]`.

## flowmoose's changelog pipeline (the part that actually has logic)

`workflows/flowmoose/.github/scripts/` is where the non-trivial code lives. The pipeline runs in this order on every release/snapshot:

1. **`version-derive.sh <release <tag>|snapshot|pr>`** — emits the marketing version on stdout. `release` parses `v1.2.3` (or `refs/tags/v1.2.3`); `snapshot`/`pr` run `git describe --tags --long --match='v*.*.*' --exclude='*-beta-*'`. Callers must use `actions/checkout` with `fetch-depth: 0`, otherwise `git describe` fails. The `--long` form is intentional — it always produces `X.Y.Z-N-gSHA` even on a tag, so each snapshot has a unique marketing version (LB-402).
2. **`generate-changelog.sh`** — reads existing `CHANGELOG.json` from S3 (falls back to `Config/CHANGELOG.json` seed), then walks `git log` for new PR-merge entries (filtered by trailing `(#NN)` suffix, per LB-326 — direct pushes are deliberately ignored). Idempotency key is `{version, channel}` for stable and `{version, build, channel}` for beta. The **`PR_TITLE` + `PR_NUMBER` env-var path** is the post-LB-397 beta workaround: on `pull_request: closed`, HEAD is a synthetic merge commit whose `HEAD~1..HEAD` doesn't carry `(#NN)`, so the script bypasses git-log and emits one entry built from the event payload.
3. **`enrich-changelog-with-jira.sh`** — for `versions[0].entries[]`, extracts `LB-NNN` from `entry.title` (or prefers an explicit `entry.jira_key`), fetches `/rest/api/3/issue/<key>?fields=summary`, and replaces `entry.title` with the Jira summary. Only `versions[0]` is touched; history is immutable. **The script never fails the build** — missing token, 401, 404, network errors all log `::warning::` (or `::error::` for 401) and leave the original title.
4. **`update-appcast.sh`** — `generate_appcast` doesn't emit `<description>`, so this script finds the matching `<item>` (by `sparkle:version` for snapshots — build number is the unique key — or `sparkle:shortVersionString` for stable releases) and injects a CDATA description. Then it trims to `APPCAST_MAX_ITEMS` (default 20). filefillet and macpacker have an older AWK-based variant of this script that hardcodes a trim to 3 items.

**Convention enforcement**: PR titles must contain an `LB-NNN` Jira key for the Jira enrichment step to do anything useful, and squash-merge commits to `main` must end with `(#NN)` for the stable channel's git-log walk to pick them up.

## Running the flowmoose unit tests

Bash tests for the changelog scripts live in `workflows/flowmoose/.github/scripts/tests/`. They run directly with bash from the **flowmoose subdirectory** (they resolve paths relative to `$REPO_ROOT = SCRIPT_DIR/../../..`):

```bash
cd workflows/flowmoose
bash .github/scripts/tests/test-version-derive.sh
bash .github/scripts/tests/test-enrich-changelog.sh
bash .github/scripts/tests/test-generate-changelog-beta-from-pr.sh
```

Caveat: `test-version-derive.sh`'s `snapshot`/`pr` cases call `git describe` against the **current repo's** history — they're written for the originating flowmoose repo and will fail or produce odd results when run from inside `research-ci` (which has no `v*.*.*` tags). `test-enrich-changelog.sh` is self-contained (it spins up a mock HTTP server) and works anywhere with `python3` and `curl`.

## Required GitHub secrets and vars (across all three workflows)

Don't hardcode these — they're read from `secrets.*` and `vars.*` in every workflow:

- **Signing**: `DEVELOPER_ID_P12_BASE64`, `CERTIFICATE_PASSWORD`, `KEYCHAIN_PASSWORD`, `PROV_PROF_DEVID_BASE64` (+ `_FINDER_BASE64`, `_QL_BASE64` for macpacker direct; `PROV_PROF_STORE_*` for macpacker store).
- **Apple**: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_BASE64`.
- **Sparkle**: `SPARKLE_ED_PRIVATE_KEY` (EdDSA private key piped to `generate_appcast --ed-key-file -`).
- **AWS**: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (region hardcoded to `eu-central-1`).
- **Jira (flowmoose)**: `JIRA_USER_EMAIL`, `JIRA_API_TOKEN`. Empty token → enrichment no-ops cleanly.
- **Vars**: `SCHEME_NAME`, `BUNDLE_ID`, `PRODUCT_NAME`, `S3_DISTRIBUTION_PATH`, `S3_DOWNLOAD_URL`. macpacker also has `BUNDLE_ID_FINDER`, `BUNDLE_ID_QUICKLOOK`, `SCHEME_NAME_STORE`. flowmoose adds `JIRA_BASE_URL`.

## Editing patterns

- **The end state is one workflow across all three apps.** Drift exists because filefillet and macpacker haven't been brought up to FlowMoose's level yet, not because they should stay simpler. Propagating a stabilized FlowMoose pattern to the other two is in-scope work, not feature creep.
- **Move incrementally.** Prove a change in FlowMoose, then port to filefillet, then macpacker. The user has explicitly asked for step-by-step — don't roll a single change across all three apps in one pass unless it's a trivially shared snippet (e.g. a one-line `aws s3 cp` flag).
- **Cross-app shared steps (keychain setup, S3 upload, ExportOptions.plist) should still land in all three at once** to keep the diffs informative while the unification is in flight.
- **`update-appcast.sh` exists in all three** but the FlowMoose version (Python, takes `NOTES` env var, trims to 20) is incompatible with the filefillet/macpacker version (Bash/AWK, reads `CHANGELOG_PATH`, trims to 3) — these are separate scripts that share a name. The FlowMoose variant is the forward direction; the others will be replaced when item (2) of the roadmap lands.
