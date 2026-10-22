# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

The **canonical shared CI/CD workflows for every LeanBytes and sarensw Apple app** — iPhone/iPad (App Store via TestFlight, Ad Hoc) and Mac (Developer ID Direct with Sparkle, Mac App Store via TestFlight). Each app repo carries four tiny trigger-only shells that call the orchestrators here via `uses: LeanBytes/workflows-macos/.github/workflows/<orchestrator>.yml@<tag>`.

**v0.6.0 folded `LeanBytes/workflows-ios` back in** (issue #32). workflows-ios was a fork cut down to iOS; it gets only blocking fixes until its last app has moved, then it is archived. The last step of that plan renames this repo to **`workflows-apple`** (v1.0.0). New work lands here, never in workflows-ios.

Layout: `.github/workflows/_build-{ios,mac-store,mac-direct}.yml` are the internal callees (named by platform); `distribute-pr.yml`, `distribute.yml`, `distribute-release.yml`, `distribute-alpha.yml` are the orchestrators; `_test.yml` and `memory-watch.yml` are standalone reusables; `.github/scripts/` holds `products.py` (the planning brain), `profiles.py` (profiles from App Store Connect) and helpers; each app repo carries one `Config/products/<id>.json` per product; `examples/per-app/` has the shell templates; `MIGRATING.md` takes an app from any earlier line to the current one; `tests/` holds the offline suite.

## The apps

| App | Legs | Notes |
|---|---|---|
| **CircleOfTrials** | iOS app-store; macOS app-store | First proof app for v0.6 (one product file for both platforms). |
| **FlowMoose** | macOS direct (Sparkle stable + beta); macOS app-store (`.mas` bundle, `Release Store`) | Tuist, LFS (Whisper `ggml-base.bin`), the classic leading edge. |
| **MacPacker** (`sarensw`, public) | macOS direct (Sparkle); macOS app-store; Finder + Quick Look extensions | GitHub-hosted runners; separate Apple account; holds every secret at repo level. |
| **VokabelLatein**, **PrintableCalendarTemplates** (`sarensw`) | iOS ad-hoc | Still on workflows-ios v0.2.0; need the App Store Connect key added to move. |
| **SandboxPilot**, **framebeast** | macOS direct; macOS app-store (`.mas`) | framebeast: S3 only, no Sparkle. |
| **TailBeat** | two products, each macOS direct (Sparkle) | |
| **groceryflow** | iOS app-store | On workflows-ios v0.4.0. |
| **FileFillet** | two products; Direct (Sparkle) + App Store built but not uploaded | Main product signs Direct with a **legacy team's** Developer ID — open question for v0.6 (its profiles can't come from the LeanBytes key). |

The plan moves CircleOfTrials, FlowMoose, MacPacker and VokabelLatein first (one per kind of leg), then the rest. **Prove on one app first, then port**; never roll a change across all apps in one pass.

## Product file and legs (v0.6)

Each product is one self-contained **`Config/products/<id>.json`**: identity (`scheme`, `bundle-id`, `product-name`, `configuration`), a **`platforms`** block, optional `source-paths`, and a mandatory inline `changelog` (`versions[0].version` = the version being built toward). `products.py` expands `platforms` into **legs**, one per platform/channel pair:

| Pair | Callee | Profile type | Export method | Ships as |
|---|---|---|---|---|
| `ios` / `app-store` | `_build-ios.yml` | `IOS_APP_STORE` | `app-store-connect` | `.ipa` → `altool --type ios` |
| `ios` / `ad-hoc` | `_build-ios.yml` | `IOS_APP_ADHOC` | `release-testing` | `.ipa` + manifest on S3 (`<dist>/<bundle-id>/app.ipa`, stable link) |
| `macos` / `app-store` | `_build-mac-store.yml` | `MAC_APP_STORE` | `app-store-connect` (+ installer cert) | `.pkg` → `altool --type macos` |
| `macos` / `direct` | `_build-mac-direct.yml` | `MAC_APP_DIRECT` | `developer-id` | notarized DMG + ZIP on S3, Sparkle |

A leg object overrides `scheme`/`bundle-id`/`configuration`/`product-name`; app-store and ad-hoc legs take `distribute` (false = build, don't upload); direct legs take `appcast`, `s3-subpath`, `appcast-filename`, `appcast-seed-path`, `changelog-filename`; any leg takes `cert-secret`/`cert-password-secret` (another certificate's secret names, e.g. FileFillet's legacy team), `asc-key` (`"alt"`: the `ASC_*_ALT` key for that leg's profiles, notarization and upload, #38) and `team` (its team ID: profiles from another team fail, and a Direct app's signature is checked too). Unknown leg keys fail. **Retired v0.5/workflows-ios keys** (`platform`, `channel`, `build-*`, `distribute-app-store`, `distribute-appcast`, `scheme-store`, `bundle-id-store`, `has-finder`/`has-quicklook` + extension bundle IDs, every `*-profile-secret`, top-level `s3-subpath`/`appcast-*`/`changelog-filename`/`cert-secret`/`devid-cert-*`, top-level `distribute`) each fail with the replacement in the message — keep that table (`RETIRED` in `products.py`) when adding keys. `tvos`/`visionos` are designed in and rejected as "not supported yet" until the first app ships there (they'd use `_build-ios.yml` with their own destination and profile type).

## Versioning model

- **Tags mark builds that reach customers on their own.** Only Direct builds get them: `<prefix><ver>-beta.N` (auto, on push), `<prefix><ver>-alpha.N` (manual alpha), and the release `<prefix><ver>` (pushed by hand). App Store and Ad Hoc builds get **no tags** — TestFlight has no stages, the build you tested is the one you submit. The user rejected `-build.N` tags ("This is only for external distribution"). The prefix is bare `v` for the primary product (the one without `id`, ≤1 per repo) and `<id>-v` otherwise.
- **Marketing version:** Direct `<ver>-beta.N` / bare `<ver>` on release; every other leg bare `<ver>` always (ASC rejects suffixes); the timestamp build number (`date -u +%y%m%d%H%M%S`) tells builds apart.
- **Gate (`products.py plan`, per product):** builds only when the version is unreleased (no bare `<prefix><ver>` tag) AND it changed — with a Direct leg since its last `-beta.N` tag (unchanged from v0.5), without one since **`SINCE`, the head commit of the last successful run** of the caller's workflow on main (`distribute.yml`'s "Find the last successful run" step, via the runs API; needs `actions: read` in the shell, falls back to `github.event.before` with a warning). Not the push's own `before`: a failed run, a `[skip ci]` push, or a queued run GitHub cancels for a newer one (one pending run per concurrency group) would lose its changes for good — the review of #32 caught that. Empty/zero `SINCE` (no successful run yet) or an unresolvable one (force push) counts as changed. `source-paths` makes code-only changes count; without it `plan` warns on every skip.
- **Release (`plan-release`):** the tag → its product → validated against `changelog.versions[0]` → **only the Direct leg** rebuilds (stable feed, `Changelog.json`, GitHub Release). A store-only product's release tag only marks what shipped (and idles the version).
- **Alpha (`plan-alpha`):** one product (`product-id`, optional with one product), every leg: App Store legs exported with `testFlightInternalTestingOnly` (never external/App Store), Direct + Ad Hoc to an unlisted `alpha/<label>/` S3 prefix; tag `-alpha.N` only with a Direct leg; the base must be unreleased.
- **`force`** (manual checkbox on `distribute.yml`) → `ASSUME_CHANGED='*'`: overrides "nothing changed", never "already released" (warns loudly). **Empty `ASSUME_CHANGED` counts as unset** (`if not inj`) — load-bearing, the off position renders to `""`.

## Signing and provisioning profiles

**Profiles come from App Store Connect at build time — none is stored in GitHub.** Each build callee's first step after the checkouts runs `profiles.py fetch --type <profile type> --install` with the App Store Connect key: every ACTIVE profile of that type the team has (hand-made preferred over Xcode-managed, then latest expiry) goes into `RUNNER_TEMP` (Direct: `WORK_DIR/profiles`) and the two directories Xcode reads; `installed.txt` records only what wasn't there before, and `cleanup` removes exactly that.

- **Archive** passes `profiles.py archive-args`: `CODE_SIGN_STYLE=Manual`, the team, the distribution identity, and `PROVISIONING_PROFILE_SPECIFIER=$(PP_$(PRODUCT_BUNDLE_IDENTIFIER:c99extidentifier))` plus one `PP_<bundle id as C identifier>=<profile UUID>` per fetched profile. Each target resolves **its own** profile by bundle ID; a target without one (a framework) resolves to empty. `:c99extidentifier` is the operator Xcode's default `PRODUCT_MODULE_NAME` uses. UUIDs, not names (a renewed profile can share a name).
- **Export** writes ExportOptions via `profiles.py export-options`: every `.app`/`.appex` in the archive (not inside a `.framework`) mapped bundle ID → profile UUID, `signingStyle manual`, `teamID`, and for `app-store-connect` `uploadSymbols` + `manageAppVersionAndBuildNumber=false` (+ `testFlightInternalTestingOnly` for alphas).
- **Disproven, don't propose again:** archiving with a placeholder/ad-hoc signature (`CODE_SIGN_IDENTITY=-`) and signing only at export — on Xcode 27.1 any iOS target with an entitlement refuses to archive without a profile. And a literal `PROVISIONING_PROFILE_SPECIFIER=<name>` on the command line signs every target with one profile (the old workflows-ios#4 workaround). `tests/run.sh` asserts no literal specifier exists.
- **One key per leg, one team per key.** A key sees only its own team's profiles, so a product with legs in two teams (FileFillet: Direct stays in its old team for signing continuity, App Store and Pro in LeanBytes) gives the other team's leg `"asc-key": "alt"`. `--team` on `archive-args`/`export-options` fails when the fetched profiles belong to another team than the leg's `team`; `build-direct.sh verify` also checks the exported app's `TeamIdentifier`. The certificate alone can't move a leg: a profile accepts only its own team's certificates.
- **The key needs the Admin role** to read profiles (a 403 says so). LeanBytes' org key was proven to read 16 profiles on 2026-10-21. MacPacker uses its own account's key; whether an Admin key may sit in that public repo is an open decision.

## Shared workflow architecture

Internal callees (`workflow_call` only; shells call the orchestrators, never these):

- **`_build-ios.yml`** — iPhone/iPad, both channels (`profile-type` + `export-method` inputs). Apple Distribution cert only; `.ipa` artifact.
- **`_build-mac-store.yml`** — Mac App Store. Apple Distribution + Mac Installer Distribution certs; `.pkg` artifact (installer cert `3rd Party Mac Developer Installer`).
- **`_build-mac-direct.yml`** — Developer ID. The logic lives in **`.github/scripts/build-direct.sh`** (single source of truth, also run locally by `scripts/build-local.sh`); the workflow runs ONE phase per named step: `profiles → setup → [pre-build hooks] → signing → archive → post-build → export → notarize → staple → verify → package → verify-packages → cleanup`. One phase ↔ one step; `tests/run.sh` checks the lockstep. `profiles` is the first phase and wipes `WORK_DIR` (cold DerivedData every run).

All three: checkout → `.shared-ci` checkout at `job.workflow_sha` → **profiles (before any app code: Tuist, SwiftPM plugins, the pre-build script)** → resolve/Tuist → pre-build cache + script → keychain → archive (bounded by `archive-timeout-minutes`) → post-build hook on the `.app` inside the archive → export → upload artifact → cleanup (`if: always()`).

Orchestrators:

- **`distribute-pr.yml`** — `pull_request`. `discover` validates every product file and emits `legs`; one `compile` matrix job over **every leg** with that leg's scheme + configuration + destination, `xcodebuild build` unsigned (`CODE_SIGNING_ALLOWED=NO`), never archive. **Nothing in it is conditional on `run-tests`** (#21: gating the compile hid that MacPacker compiled nothing for months). Fork-PR safe (product files ship with the checkout).
- **`distribute.yml`** (was `distribute-beta.yml`) — push to main + manual `force`. `prepare` (`plan`) → `test` (opt-in gate) → `build-ios` / `build-mac-store` / `build-mac-direct` (each a matrix over its subset, gated on `has-<callee>`) → `publish`: altool for every app-store leg (iPhone `.ipa`, Mac `.pkg`) → Ad Hoc IPA + manifest to S3 → Direct DMG/ZIP to S3 → beta appcast → per Direct product its `-beta.N` tag + pre-release, **last**. Repo-wide `concurrency`, never cancelled.
- **`distribute-release.yml`** — tags `v[0-9]*` / `*-v[0-9]*` minus `-beta.*`/`-alpha.*`. `plan-release` → `build-mac-direct` (if the product has a Direct leg) → `publish-release`: S3, `Changelog.json` (only the product's `.changelog`, never its build identity), stable appcast, GitHub Release last (+ opt-in Discussion).
- **`distribute-alpha.yml`** — manual, any branch. `plan-alpha` → the three build jobs (App Store legs `internal-only`) → `publish-alpha`: TestFlight (internal), unlisted S3 prefix for Direct + Ad Hoc, the `-alpha.N` tag when there's a Direct leg. Repo-wide `concurrency` serializes the counter.

Standalone reusables: **`_test.yml`** (`run-tests.sh`: `swift` / `xcodebuild` / `both`; `test-destination` input, default the Mac — the orchestrators default it to an iOS Simulator for an iPhone-only first product) and **`memory-watch.yml`** (Mac, unsigned, leak = successful run).

## Load-bearing details

Bugs someone already paid for. Don't "clean them up".

- **`\x1f` (Unit Separator), never tab**, in the publish leg/product tables. Tab is IFS-whitespace, so `read` collapses runs of it and an empty column (an empty `s3-subpath`) shifts every later field. `tr '\037' '\t'` only for the human-readable echo.
- **`rm -rf /tmp/build` before every store/iOS archive** (LB-459). `/tmp` persists across jobs on a self-hosted runner; a killed job's export otherwise rides along in the upload glob. Direct: `phase_package` clears `OUTPUT_DIR`'s DMG/ZIPs, `phase_profiles` wipes `WORK_DIR`.
- **`set +e` around the `altool` capture.** Under errexit a non-zero exit aborts the step before the classifier runs (v0.3.46).
- **`classify-upload.sh` is the single definition** of "did the upload land?", sourced by `distribute.yml`, `distribute-alpha.yml` and `tests/run.sh`. `ITMS-90189` → `already-present` (benign); `-19232` → **`failed`**. Never widen the pattern to "already been used".
- **`manageAppVersionAndBuildNumber` must be `false`** for app-store-connect exports — its default rewrites `CFBundleVersion` and destroys the timestamp build number. Set in `profiles.py export-options`, asserted by its selftest.
- **Every `create-keychain` is followed by `set-keychain-settings` (no `-t`/`-l`) + `unlock-keychain`** — a fresh keychain's 300s idle-lock otherwise fires mid-archive and hangs codesign forever (v0.5.1). Asserted for all three signing sites.
- **One runner process per macOS user.** The keychain search list is per user; two jobs signing at once under one user take each other's `build.keychain` away. Not fixable with per-job keychain names (codesign and export read the search list) — so don't try; run one runner per user.
- **Secrets only in the steps that use them**, never a job-level `env:` (the app's pre-build script, SwiftPM plugins and the Tuist installer would see them). Asserted per callee in `tests/run.sh`. A malicious pre-build script could still tamper with `.shared-ci` before a later step runs; only a separate signing job would remove that.
- **A job `if:` cannot read `matrix`, and an empty matrix throws** rather than skipping — hence `prepare` emits `<callee>-legs` subsets + `has-<callee>` booleans and each build job gates on its boolean. `matrix.*` is illegal in `uses:`.
- **`download-artifact` flattens a lone matched artifact** into the base path with no subdir; two or more get subdirs. The re-nest loop in each publish job is why a single-leg run doesn't report "No .ipa / no .pkg / no DMG".
- **Publish gates exclude `cancelled`**, not just `failure` (#10): a wedged build job would otherwise publish half a release. `skipped` stays allowed (a product without a leg of some kind).
- **`.shared-ci` is checked out at `job.workflow_sha`**, the called workflow's own commit, so a caller pinned to a tag runs that tag's scripts. Until v0.5.10 / v0.6.1 it said `github.job_workflow_sha`, which doesn't exist: the ref came out empty, `actions/checkout` took the default branch, and every pinned caller ran main's scripts — v0.6.0 landing on main broke every v0.5 caller that way (#34). The `|| 'job.workflow_sha-is-empty'` fallback fails the checkout instead of falling back to main; `tests/run.sh` asserts that exact `ref:` on every shared checkout.
- **Tuist comes from the app's own pin.** Every Tuist install runs `mise install`, then `mise which tuist`, which stops an app without a pin (`mise exec` alone would run any Tuist the runner has), then logs `mise exec -- tuist version`. Never `mise use`: it rewrites the app's `mise.toml`. Never `tuist --version`: Tuist 4 rejects it, so until v0.5.11 / v0.6.2 the probe always fell through to `mise use tuist@latest`. Never `latest`: tuist/tuist's release list leads with canaries and other components, and on 2026-10-22 mise stopped finding a CLI release in it (#39). `tests/run.sh` asserts every install.
- **An `"asc-key": "alt"` leg gets the `*_ALT` key or none**: `secrets[matrix.leg.asc-key == 'alt' && 'ASC_KEY_ID_ALT' || 'ASC_KEY_ID']`, never `… && secrets.ASC_KEY_ID_ALT || secrets.ASC_KEY_ID`, which falls back to the default team's key when the ALT secret is missing and signs the leg in the wrong team (#38). The upload loops pick per leg the same way. Asserted in `tests/run.sh`.
- **`runs-on*` inputs are JSON-encoded** and consumed with `fromJSON()`; each has a same-named `RUNS_ON_*` Variable override (`vars.X || fromJSON(inputs.Y)`, bare label, never `fromJSON(vars…)`). No workflow but `selftest.yml` hardcodes a runner — asserted. `prepare`/`discover` must be pinnable too, or a repo without a self-hosted runner deadlocks silently on job one.
- **Post-build hook:** quote the path (`Release Store` puts a space in `BUILT_PRODUCTS_DIR`), and feed `awk` from a here-string, never a pipe (SIGPIPE past 64 KiB of `-showBuildSettings`, #28).
- **Public repos keep build artifacts one day** (`github.event.repository.private == false && 1 || inputs.artifact-retention-days`): anyone signed in to GitHub can download them.
- **python.org's Python ships without root certificates**, so `profiles.py` verifies HTTPS against `/etc/ssl/cert.pem` explicitly.
- **Every `actions/*` on a Node 24 major** (checkout@v6, cache@v5 incl. sub-actions, upload-artifact@v7, download-artifact@v8); `tests/run.sh` enforces minimums and fails on an unknown action.
- **`selftest.yml` runs on `ubuntu-latest`** — no self-hosted runner is attached to this repo; a self-hosted job here queued silently for 27 days once.

## Scripts in `.github/scripts/`

- **`products.py`** — `discover` / `plan` / `plan-release` / `plan-alpha`; pure stdlib; offline-testable via injected `GIT_TAGS` / `ASSUME_CHANGED` / `BUILD_NUMBER` / `SINCE` / `PRODUCTS_DIR`. Test defaults (`test-scheme` + `test-destination`) come from ONE leg — the first product's Mac leg if it has one, else its first leg. Emits `products`, `legs`, `<callee>-legs` + `has-<callee>`, `has-appcast`, `has-any`, `build-number`, test defaults.
- **`profiles.py`** — `fetch [--install]` / `cleanup` / `archive-args` / `export-options` / `selftest`. JWT ES256 via `openssl` (stdlib can't sign ECDSA; DER → raw r‖s). Key from `ASC_KEY_BASE64` (CI, on disk only for the one openssl call) or `ASC_KEY_PATH`. Prints names, bundle IDs and dates only — never a token or profile content (Ad Hoc profiles list device IDs).
- **`build-direct.sh`** — the Direct core (see above); env-driven, no cross-phase in-memory state.
- **`classify-upload.sh`**, **`manifest.sh`** (Ad Hoc `itms-services` manifest; the S3 upload must be `text/xml` or iOS refuses it), **`changelog-from-json.sh`** (feat/fix/core/lang/release; `chore` dropped silently, anything else loudly, never on stdout), **`update-appcast.sh`**, **`run-tests.sh`**, **`memory_watch.py`**, **`jira_client.py`**, **`create_jira_ticket.py`**, **`create_test_ticket.py`**.

## Secrets and vars

Team secrets (org-level in LeanBytes; repo copies in `sarensw` repos): `APPLE_DISTR_P12_BASE64`/`_PASSWORD`, `MAC_DISTR_P12_BASE64`/`_PASSWORD`, `DEVELOPER_ID_P12_BASE64`/`_PASSWORD`, `KEYCHAIN_PASSWORD`, `ASC_KEY_ID`/`ASC_ISSUER_ID`/`ASC_KEY_BASE64` (Admin), `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`, `JIRA_API_TOKEN`. Per app: `SPARKLE_ED_PRIVATE_KEY` (Direct with appcast). Optional alternates a leg can name: `APPLE_DISTR_P12_ALT_BASE64`/`APPLE_DISTR_PASSWORD_ALT`, `DEVELOPER_ID_P12_ALT_BASE64`/`DEVELOPER_ID_PASSWORD_ALT`, and another team's key `ASC_KEY_ID_ALT`/`ASC_ISSUER_ID_ALT`/`ASC_KEY_ALT_BASE64` (`"asc-key": "alt"`). `SHARED_WORKFLOWS_TOKEN` is optional (only a private fork needs it). **No `PROV_PROF_*` anywhere** — asserted.

Vars: `S3_DISTRIBUTION_PATH`, `S3_DOWNLOAD_URL`, the `RUNS_ON_*` overrides (`RUNS_ON_BUILD_IOS`, `RUNS_ON_BUILD_MAC_STORE`, `RUNS_ON_BUILD_MAC_DIRECT`, `RUNS_ON_TEST`, `RUNS_ON_BUILD`, `RUNS_ON_PUBLISH`, `RUNS_ON_DISCOVER`, `RUNS_ON_PREPARE`), Jira vars for tickets. The old org variable `RUNS_ON_BUILD_STORE` is no longer read.

## Editing patterns

- **A breaking change updates `MIGRATING.md` in the same PR**: the key, input, secret or variable, what replaces it, and what an app has to do. `tests/run.sh` fails when a retired product-file key is missing from it.
- **All workflow logic lives here; per-app shells only declare triggers, inputs and the explicit secrets block.** Never `secrets: inherit` in the examples (same-org only, and it passes every secret).
- **`tests/run.sh` must stay green** (`bash tests/run.sh`, ~10 s, needs python3, git, openssl, yq). Add a case for every behaviour change in `products.py` or `profiles.py`. It also checks the wiring of every `uses:` call against the callee's declared inputs and secrets (actionlint can't see across `uses:`), so a renamed input fails here instead of in an app repo. Lint with `actionlint -ignore 'property "workflow_sha" is not defined in object type \{check_run_id' -ignore 'shellcheck reported issue' .github/workflows/*.yml`.
- **When bumping the tag, bump every `@vX.Y.Z` inside the shared workflows AND in `examples/per-app/`** in the same commit.
- **When fixing a bug in a copied script, check workflows-ios** until it is archived.
- **Prove changes end to end on one app first.** TestFlight is a free smoke test (an upload triggers no review; internal testers are unlimited); `"distribute": false` on a leg builds and signs without contacting App Store Connect for uploads (profiles are still fetched).

## Roadmap (remaining work)

1. **Prove v0.6 on four apps** (CircleOfTrials incl. one alpha, FlowMoose incl. one release, MacPacker on hosted runners, VokabelLatein Ad Hoc), then move the other six; delete each app's `PROV_PROF_*` secrets after its first green run.
2. **Rename to `workflows-apple` v1.0.0** and archive workflows-ios.
3. **Hardening not in v0.6.0:** pin `actions/*` to commit SHAs; a ruleset blocking moves/deletes of `v*` tags; a separate signing job (true isolation of certificates from app code).
4. **Open decisions:** FileFillet's legacy-team Direct product; whether public MacPacker may hold an Admin key; tvOS/visionOS when the first app ships there; macpacker localization + App Store (not started).
