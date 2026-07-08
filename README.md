# workflows-macos

Reusable GitHub Actions workflows for macOS app distribution — Developer ID Direct (Sparkle) + App Store (TestFlight / App Store Connect). Drop them into any macOS app repo that ships either or both channels.

> **Heads up — strongly opinionated.** These workflows are tailored to how Stephan Arenswald (personal) and **LeanBytes** ship macOS apps. They power **MacPacker**, **FlowMoose**, and **FileFillet** in production. The choices baked in — Developer ID + App Store driven from a single repo, Sparkle 2 with stable + beta channels, AWS S3 for direct-download hosting in `eu-central-1`, timestamp-based build numbers, one self-contained `Config/products/<id>.json` per product (build identity + inline changelog) as the source of truth — reflect that specific use case. If your distribution model is different, expect to patch rather than just configure.

Adding a new app means: dropping one `Config/products/<id>.json` per product (build identity + inline changelog) in your repo, setting ~9 secrets + two S3 vars, and copying three **trigger-only** shell workflows into `.github/workflows/` (they *discover* your products — no `products` input). No build/sign/notarize/upload code lives in the consumer repo.

## Architecture

```
Per-app shell (trigger-only)          Shared orchestrator                            Shared callees
────────────────────────────         ────────────────────────────────              ──────────────────────────
distribute-pr.yml           ──→   distribute-pr.yml                          ┐
  on: pull_request                   discover → verify (compile each product) │
                                                                              │
distribute-beta.yml         ──→   distribute-beta.yml                         │   _build-direct.yml
  on: push branches:[main]           prepare (plan-beta: changelog-driven  ───┼──→  (direct-build-<id>)
                                     cutting set) → build-* (matrix) →         │
                                     publish (per product: <id>-v<ver>-beta.N  │   _build-app-store.yml
distribute-release.yml      ──→      tag + pre-release)                        ┘    (app-store-build-<id>)
  on: push tags '<id>-v*'          distribute-release.yml
       (excl. -beta / -alpha)        prepare (plan-release: parse tag →
                                     scoped product) → build-* → publish-release
```

The build callees produce **artifacts** (DMG/ZIP for Direct, `.pkg` for App Store). Orchestrators decide the publishing sequence so failure mid-channel doesn't half-publish.

## How versioning works (per-product, self-contained)

Each product is one **`Config/products/<id>.json`** in your app repo — its build identity plus an inline **`changelog`** object that is the source of truth for **that product's** next-to-ship version + release notes. The `changelog` value uses the schema shown below (identical to the old top-level `Config/Changelog.json`); your app loads it at runtime for its What's New view, and CI reads the same object for the appcast/Release notes — one author, one place, per product.

```jsonc
{
  "comingNext": {
    "en": "Optional teaser shown in your app's What's New view",
    "de": "Optionaler Teaser für die What's-New-Ansicht der App"
  },
  "versions": [
    {
      "version": "2.12.0",          // ← versions[0]: in-progress / next to ship
      "items": [
        {"type": "feat", "title": {"en": "Show folder color from macOS 26 Tahoe"}, "issues": ["MP-417", "MP-418"]},
        {"type": "fix",  "title": {"en": "First NAS transfer fails on cold drive"}}
      ]
    },
    {
      "version": "2.11.0",          // ← already shipped
      "items": [ /* ... */ ]
    }
  ]
}
```

`comingNext` and each `item.title` are **locale-keyed maps** (`{"en": "...", "de": "..."}`). The shared workflows currently render the `en` value into the appcast description and GH Release body; the other locales are picked up by your app's in-product What's New view directly from the same file. `comingNext` is for the app UI only — it does not appear in the appcast or GH Release notes.

**Item types:** `feat` → New Features, `fix` → Bug Fixes, `core` → Improvements. Anything else (including legacy `chore`) is silently dropped from the customer-facing render.

**Optional `issues` field.** Each item may carry an `"issues"` **array of strings** — the Jira keys (`"MP-417"`) and/or GitHub issues (`"#98"`) the change traces back to. Use a one-element list for a single ticket (`["MP-417"]`), several for a change that closes more than one, and omit the key entirely when there's none. It's pure provenance: both the CI pipeline and the app's in-product What's New view **ignore** it, so it never reaches customers. (It replaced the earlier numeric `pr` field, which was likewise unused — `issues` is more useful to a human reading the file, holds multiple tickets per change, and you set it without waiting for a PR number.)

There is **no per-item product routing** — each product has its own `Config/products/<id>.json` with its own `changelog`, so its items are already scoped to it. (A pro superset simply repeats the shared items in its own file plus its extras; the small duplication is accepted for the self-contained model.)

**Tags mark ship moments (per product).** The **primary** product — the one that omits `id` — uses **bare `v*`** tags; every other product is prefixed `<id>-v*`. The prefix is a git/CI identifier only — it never enters the app (`CFBundleShortVersionString` is always the bare `X.Y.Z`). At most one product per repo may omit `id`.
- `vX.Y.Z` (primary) / `<id>-vX.Y.Z` — stable release. You push it manually; CI validates it against that product's `changelog.versions[0].version`.
- `vX.Y.Z-beta.N` / `<id>-vX.Y.Z-beta.N` — Nth beta. Auto-pushed on push→main, **only when that product's file changed** (changelog-driven — see below).

**Marketing version per channel** (Apple's iTMS rejects non-`N.N.N` strings in `CFBundleShortVersionString`, so we split):
- **Direct / Sparkle:** `<next>-beta.<N>` for betas (e.g. `2.12.0-beta.4`), bare `<next>` for releases.
- **App Store / TestFlight:** bare `<next>` always; the build number disambiguates.

**Beta is changelog-driven (the gate).** On every push to `main`, a product cuts its next beta **only when** (a) its `changelog.versions[0]` version isn't released (no `<id>-v<ver>` tag) AND (b) its own `Config/products/<id>.json` changed since its last beta. So editing only product A's changelog betas **only A**; a product sitting at an already-released version is skipped (idle), never blocked. Cut the next version by prepending a new `versions[0]` entry to that product's `changelog`.

## Per-app setup

### 0. `Config/products/<id>.json` (one per product)

Drop one file per product in `Config/products/`. Each holds build identity + a **required** inline `changelog` whose `versions[0].version` MUST be set before any CI run can produce a build for that product. Your app loads its `.changelog` at runtime for its What's New view; CI reads the same object for release notes and version derivation. Sample: [`examples/per-app/Config/products/app.json`](examples/per-app/Config/products/app.json).

### 1. Secrets

Set in your app's repo (or inherit from your org):

| Secret | Purpose | Required for |
|---|---|---|
| `DEVELOPER_ID_P12_BASE64` | Developer ID Application cert + private key (base64) | Direct |
| `DEVELOPER_ID_PASSWORD` | Password for the Developer ID p12 | Direct |
| `APPLE_DISTR_P12_BASE64` | Apple Distribution cert + private key — signs the .app | App Store |
| `APPLE_DISTR_PASSWORD` | Password for the Apple Distribution p12 | App Store |
| `MAC_DISTR_P12_BASE64` | Mac Installer Distribution cert + private key — signs the .pkg | App Store |
| `MAC_DISTR_PASSWORD` | Password for the Mac Installer Distribution p12 | App Store |
| `KEYCHAIN_PASSWORD` | Ephemeral build keychain password | Both |
| `PROV_PROF_DEVID_BASE64` | Main Developer ID provisioning profile | Direct |
| `PROV_PROF_STORE_BASE64` | Main App Store provisioning profile | App Store |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_BASE64` | App Store Connect API key | Both (notarization + altool) |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | S3 upload credentials | Direct |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle EdDSA private key | Direct (appcast signing) |
| `PROV_PROF_DEVID_FINDER_BASE64`, `PROV_PROF_STORE_FINDER_BASE64` | Finder extension profiles | If `has-finder-extension: true` |
| `PROV_PROF_DEVID_QL_BASE64`, `PROV_PROF_STORE_QL_BASE64` | Quick Look extension profiles | If `has-quicklook-extension: true` |

### 2. Vars

Only repo-level **infrastructure** lives in Variables — product identity moved into `Config/products/<id>.json` (next section).

| Var | Purpose |
|---|---|
| `S3_DISTRIBUTION_PATH` | Full S3 URI for direct downloads, e.g. `s3://my-bucket/my-app` |
| `S3_DOWNLOAD_URL` | Public base URL for the same path (download links in the run summary) |

> **v0.4.0 (breaking):** the per-product Variables `SCHEME_NAME`, `SCHEME_NAME_STORE`, `PRODUCT_NAME`, `BUNDLE_ID`(`_STORE`), and `BUNDLE_ID_FINDER` / `BUNDLE_ID_QUICKLOOK`(`_STORE`) are **retired**. That identity now lives in each `Config/products/<id>.json`. Delete the retired repo Variables when you migrate a repo to `@v0.4.2`.

### 2a. Product files (v0.4.0)

Each product is one **`Config/products/<id>.json`** in your repo — the orchestrators **discover** every `Config/products/*.json` (no `products` input in the shell). A single-product app has one file; a repo that ships two products (e.g. a free app + a pro superset) has two, and each versions, betas, and releases **independently**.

Discovery-by-glob is fork-PR safe: a fork PR strips `vars.*` and `secrets.*`, but the product files ship with the checkout, so identity is always present.

```jsonc
// Config/products/app.json
{ "id": "app", "platform": "macos",
  "scheme": "MyApp", "product-name": "MyApp", "bundle-id": "com.example.myapp",
  "scheme-store": "MyApp", "build-app-store": true, "distribute-app-store": true,
  "changelog": { "versions": [ { "version": "1.0.0", "items": [] } ] } }
```

Fields — only `id`, `scheme`/`product-name`/`bundle-id` (Direct) or `scheme-store`/`bundle-id` (App Store), and `changelog` are required; everything else is optional and inherits the shell's top-level toggle defaults:

| Field | Meaning |
|---|---|
| `id` | Short unique key — labels the build/artifact/S3 sub-path and prefixes tags (`<id>-v*`). **Omit it** (or `""`) for the *primary* product → bare `v*` tags (≤1 per repo; a non-empty `id` must equal the filename). |
| `platform` | `macos` (default) or `ios` (build leg deferred — iOS products are excluded from the mac build for now). |
| `scheme` / `product-name` / `bundle-id` | Direct build identity (`product-name` drives the `.app` + DMG/ZIP filenames). |
| `scheme-store` / `bundle-id-store` | App Store scheme + bundle id (`bundle-id-store` defaults to `bundle-id`). |
| `bundle-id-finder`(`-store`) / `bundle-id-quicklook`(`-store`), `has-finder` / `has-quicklook` | Extension bundle ids + toggles, per product. |
| `build-direct` / `build-app-store` / `distribute-app-store` / `distribute-appcast` | Per-product channel toggles (default to the shell's top-level inputs). |
| `devid-profile-secret` / `store-profile-secret` | Name of the provisioning-profile secret for this product (defaults to the shared `PROV_PROF_DEVID_BASE64` / `PROV_PROF_STORE_BASE64`). |
| `s3-subpath` | S3 + appcast sub-prefix for this product (e.g. `"pro"`; empty = the bucket root). |
| `appcast-filename` / `appcast-seed-path` | This product's Sparkle feed filename + seed. |
| `changelog-filename` | Filename for this product's published `Changelog.json` (default `Changelog.json`). Give a second product at the **same** `s3-subpath` a distinct name (e.g. `Changelog-pro.json`) so they don't overwrite each other. |
| `changelog` | **Required.** Inline release notes — today's `Config/Changelog.json` schema, verbatim (see *How versioning works*). |

For a two-product repo, copy the templates in [`examples/per-app/two-product/`](examples/per-app/two-product/). Certs, keychain, ASC key, and the Sparkle key stay **team-shared**; only the provisioning profiles are per-product — add the extra profile secrets (e.g. `PROV_PROF_DEVID_PRO_BASE64`) and name them in each product's `devid-profile-secret` / `store-profile-secret`.

### 3. Per-app xcconfig

Two app-side requirements this workflow does NOT handle for you:

```
// Config/Release.xcconfig — required for App Store apps to skip ASC's
// manual export-compliance review on every TestFlight upload
INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO
```

```
// Config/Version.xcconfig — placeholder for local debug builds only.
// CI overrides MARKETING_VERSION via xcodebuild at archive time.
MARKETING_VERSION = 0.0.0-dev
```

Your `Info.plist` must reference `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)`.

### 4. Drop in the three shell workflows

Copy from [`examples/per-app/`](examples/per-app/):

- `distribute-pr.yml`
- `distribute-beta.yml`
- `distribute-release.yml`

Pin the `uses:` line to a tag (`@v0.4.2`), not `@main`. Uncomment per-app inputs as needed.

**On secret passing.** GitHub Actions' `secrets: inherit` only crosses repository boundaries *within the same org/enterprise*. If your consumer repo lives in the **same org** as `LeanBytes/workflows-macos` (i.e. the `LeanBytes` org), you can simplify the shell to:

```yaml
jobs:
  pr:
    uses: LeanBytes/workflows-macos/.github/workflows/distribute-pr.yml@v0.4.2
    secrets: inherit
    with:
      # …
```

If your consumer repo is in a **different account or org** (a personal account, a different org, a fork without an enterprise tie), `secrets: inherit` silently passes nothing — every signing step then fails with a `security: SecKeychainItemImport` error. The example shells use the explicit `secrets:` block that works universally. Keep that block as-is unless you want the same-org shortcut.

The beta and release orchestrators expose four build/distribute toggles. In v0.4.0 these are **defaults** each product inherits when its `Config/products/<id>.json` omits them — a product can override any of them per product:

| Input | Default | Effect |
|---|---|---|
| `build-direct` | `true` | Build the .app/DMG/ZIP via `_build-direct.yml` |
| `build-app-store` | `false` | Build the .pkg via `_build-app-store.yml` |
| `distribute-app-store` | `false` | altool upload to ASC. Requires `build-app-store`. |
| `distribute-beta-appcast` *(beta only)* | `false` | Publish to the Sparkle beta channel. Requires `build-direct`. |
| `distribute-stable-appcast` *(release only)* | `true` | Publish to the Sparkle stable channel. Requires `build-direct`. |

A separate **`lfs`** input (default `false`, on every build workflow — PR, beta, release, nightly tests, memory-watch) makes `actions/checkout` pull the caller repo's git LFS files on the **build** checkouts. Flip it to `true` only when a build input is LFS-tracked (e.g. FlowMoose's Whisper `ggml-base.bin`); it's scoped to the checkouts that actually compile, so prepare/publish steps never pull the LFS payload. Apps with no LFS leave it off and are unaffected.

Common configurations:

- **Direct-only, Sparkle stable + beta channels.** `build-direct: true`, `distribute-beta-appcast: true` in the beta shell, `distribute-stable-appcast: true` in the release shell (the default).
- **Direct + App Store, no beta appcast.** `build-direct: true`, `build-app-store: true`, `distribute-app-store: true`. Beta builds go to TestFlight (not the Sparkle beta channel); stable releases go to both Sparkle stable and the App Store.
- **App Store only.** `build-direct: false`, `build-app-store: true`, `distribute-app-store: true`, `distribute-stable-appcast: false`.

Per-app build flags also available: `use-tuist` (if your Xcode project is generated by Tuist), `extra-xcodebuild-args`, `products-dir` (defaults to `Config/products`). Extension toggles + bundle ids (`has-finder` / `has-quicklook`) now live per product in the product file.

**Release trigger.** The primary product releases via bare `vX.Y.Z`, extra products via `<id>-vX.Y.Z`. Your `distribute-release.yml` shell matches **both** and excludes the beta + alpha tags of either:

```yaml
on:
  push:
    tags:
      - 'v*'          # primary product:  v2.12.0
      - '*-v*'        # extra products:   pro-v1.1.1
      - '!*-beta.*'
      - '!*-alpha.*'
```

**GH (pre-)release titles.** Stable releases get `v<X.Y.Z>` as the release title (matching the tag); beta pre-releases get `v<X.Y.Z>-beta.<N>`. The DMG and ZIP are attached to the release object as downloadable assets, so the Releases tab on the repo shows them alongside GitHub's auto-attached source archives.

**GitHub Discussions (off by default, releases only).** Set `create-discussion: true` in `distribute-release.yml`'s shell to auto-open a discussion alongside each stable release. The discussion's title matches the release title (e.g. `v0.15`); the category defaults to `Announcements` and can be overridden via `discussion-category: <name>`.

```yaml
# In your per-app distribute-release.yml shell:
with:
  create-discussion: true
  # discussion-category: Announcements   # default; override only if needed
```

**Prerequisites and caveats (test in a sandbox repo first).** The orchestrator passes `--discussion-category` to `gh release create` as a single atomic call. If the discussion API errors, the **entire release creation fails** and no release object is produced for the pushed tag. To avoid that on a real release, verify all of the following on the consumer repo before flipping the toggle on:

- Discussions enabled (`Settings → Features → Discussions` ticked).
- A category with the **exact** name you pass exists in the Discussions tab (case-sensitive).
- The caller's per-app shell grants `discussions: write` in its `permissions:` block (in addition to `contents: write`).

If any of those are wrong you'll typically see a misleading `HTTP 404: Discussion could not be created. Make sure you passed a valid category name.` — the 404 covers all three failure modes. Beta pre-releases don't create discussions either way to avoid notification noise.

**Alpha / invite builds (optional, manual).** Sometimes you want to hand a rough, early build to a hand-picked few — e.g. work on a `3.0` branch that isn't ready for a public beta — *without* putting it on the appcast, the changelog, or the Releases tab. Drop in the optional fourth shell [`examples/per-app/distribute-alpha.yml`](examples/per-app/distribute-alpha.yml) and trigger it **manually** (Actions → "Distribute Alpha" → Run workflow → pick the branch).

It builds the **same notarized DMG/ZIP a real release would** (so it opens cleanly on an invitee's Mac), uploads them to an **unlisted `alpha/<version>/` prefix** in your S3 bucket, and prints the download URL in the run summary — that's the link you send to invitees. It is deliberately off the public machinery: no Sparkle appcast, no `Changelog.json` write, no GitHub Release, no auto-update.

- **Identity** is `<base>-alpha.<N>` (e.g. `3.0.0-alpha.1`), tagged `<id>-v<base>-alpha.<N>`. Pass `product-id` — `<base>` comes from that product's `Config/products/<id>.json` `changelog.versions[0].version` (or a `version-base` dispatch input); `<N>` is auto-counted from existing `<id>-v<base>-alpha.*` tags — the same tag-counter betas use.
- **Exclude the alpha tag from your release trigger** (`!*-v*-alpha.*`, shown above) or its push fires a real release.
- **`workflow_dispatch` visibility:** the shell must live on your **default branch** for the "Run workflow" button to appear, *and* on the branch you want to build (merge or cherry-pick it onto a v3 branch that forked earlier).
- Secrets are the **Direct subset** — Developer ID + ASC (notarization) + AWS. No Sparkle key, no App Store certs.

### 5. Pre-build hooks (app-specific assets)

For apps that need extra setup on the build runner (asset downloads, codegen, etc.), the build callee exposes generic `pre-build-cache-*` + `pre-build-script` inputs. The script lives in the consumer repo, so no app-specific paths or URLs leak into the shared workflow.

Example — downloading a large model file from a public URL:

```yaml
# In your per-app shell:
with:
  pre-build-cache-path: Models/asset.bin
  pre-build-cache-key:  asset-v1
  pre-build-script:     .ci/download-asset.sh
```

```bash
# .ci/download-asset.sh inside your repo
#!/usr/bin/env bash
set -euo pipefail
SIZE=$(wc -c < Models/asset.bin 2>/dev/null || echo 0)
if [ "$SIZE" -lt 100000000 ]; then
  curl -L "https://example.com/asset.bin" -o Models/asset.bin
fi
```

The cache step runs first (restores the file if previously cached under that key); the script runs after (downloads only if missing or stale). Both are skipped when `pre-build-cache-path` is empty.

## Local builds (no CI)

Need a signed + notarized DMG/ZIP to test a fix — without burning a commit and a CI run? `scripts/build-local.sh` runs the **exact same** pipeline `_build-direct.yml` runs (same ephemeral keychain from your base64 cert, same `xcodebuild` / `notarytool` / `ditto` commands, same Gatekeeper verification) on your Mac. The workflow and the script both call one shared core — `.github/scripts/build-direct.sh` — so they can't drift.

> The notarization round-trip (~1-3 min) dominates the wall-clock; use `--skip-notarize --no-dmg` for a fast signing-only inner loop while iterating.

**One-time setup:**

1. `cp examples/local-build.env.example ~/.config/workflows-macos/<app>.env` and fill it from your app repo's GitHub Actions secrets + vars (the same base64 cert, ASC key, and scheme/bundle/product values CI uses). It holds a signing cert — keep it **outside any git repo** and `chmod 600` it.
2. Make sure any pre-build asset is present locally (e.g. FlowMoose's Whisper model), or set `PRE_BUILD_SCRIPT` in the env file.

**Run** (from your app repo, or pass `--project-dir`):

```bash
# from a workflows-macos checkout on disk:
~/path/to/workflows-macos/scripts/build-local.sh --env-file ~/.config/workflows-macos/flowmoose.env

# fast signing-only loop (skip notarization, ZIP only):
~/path/to/workflows-macos/scripts/build-local.sh --env-file … --skip-notarize --no-dmg
```

Artifacts land in `<app-repo>/dist/<PRODUCT_NAME>_<version>.{zip,dmg}`, where the version defaults to `<Changelog versions[0]>-local.<build-number>` — the `-local.` marker keeps a stray local build from being mistaken for a shipped `-beta.N`/release. **Add `dist/` (and your env file, if you keep it in-repo) to your app repo's `.gitignore`.**

**Verify it's a real, Gatekeeper-valid build** — the script does this automatically post-package; the manual equivalents are:

```bash
ditto -x -k dist/<PRODUCT_NAME>_*.zip /tmp/verify
xcrun stapler validate -v /tmp/verify/<PRODUCT_NAME>.app
spctl --assess --type execute --verbose=4 /tmp/verify/<PRODUCT_NAME>.app   # → accepted, source=Notarized Developer ID
codesign --verify --deep --strict --verbose=4 /tmp/verify/<PRODUCT_NAME>.app
```

`scripts/build-local.sh --help` lists every flag (`--version`, `--output-dir`, `--scheme`, `--keep`, …).

## Publish ordering

Both `distribute-beta.yml` and `distribute-release.yml` enforce strict sequencing in their publish job:

```
1. Render release notes from the product's inline .changelog
2. (gate) altool → ASC          if distribute-app-store
3. aws s3 cp DMG/ZIP            (silent — no Sparkle client polls these without an appcast pointer)
4. (release only) aws s3 cp Changelog.json  (the product's .changelog, extracted, at its s3-subpath)
5. (gate) appcast.xml update    if distribute-appcast
6. per product: git push <id>-v<ver>-beta.N   (beta)
7. gh release create <id>-v*    ← only if all prior steps succeeded
```

The appcast update is the "go-live" moment for Sparkle clients; the GH (pre-)release is created last. Beta cuts each product's own tag + pre-release; release creates one Release for the pushed `<id>-v*` tag. A failure anywhere short-circuits the rest, so you never end up with a half-published version.

## Memory-leak watch

A reusable workflow ([`memory-watch.yml`](.github/workflows/memory-watch.yml)) that builds an app **unsigned**, runs it for hours on a runner, and samples its resident memory to catch leaks (unbounded growth). It reuses this repo's build knowledge — Tuist install/generate, runner selection, the `.shared-ci` script sharing — so a calling app sets only a few inputs; no signing, no release machinery.

Outcome semantics are deliberate — **a leak is a successful watch**:
- healthy → job success
- leak detected → file a Jira ticket (when `file-jira-on-leak`) → job **success**
- infra/watch error (build failed, app wouldn't launch, the watcher crashed) → job **fail**

`memory_watch.py` samples RSS via `ps`, applies a hard cap plus a slope-and-floor trend rule after a warmup window, and exits `0` (healthy) / `2` (leak) / `3` (error). Drop in the [`examples/per-app/nightly-memory-watch.yml`](examples/per-app/nightly-memory-watch.yml) shell (it owns the cron), point `runs-on` at a runner (**multi-hour watches need self-hosted** — GitHub-hosted macOS caps a job at 6h), and optionally wire Jira (`JIRA_*` vars + `JIRA_API_TOKEN`). A per-commit cache gate watches each commit on `main` exactly once.

## Testing

Run an app's Swift tests at three points — all **opt-in** per app via `run-tests`. The logic is one reusable workflow ([`_test.yml`](.github/workflows/_test.yml)) wrapping one shared script ([`run-tests.sh`](.github/scripts/run-tests.sh)):

- **On PRs** (`distribute-pr.yml`, `run-tests: true`) — a build + test run replaces the compile-only check; a failure turns the PR check **red** (no ticket — the author fixes before merge).
- **On merge → beta** (`distribute-beta.yml`, `run-tests: true`) — tests **gate** the beta: if they fail, the build/publish jobs skip (**no beta is published**), the workflow fails, and a Jira ticket is filed.
- **Nightly** — drop in [`examples/per-app/nightly-tests.yml`](examples/per-app/nightly-tests.yml) (it owns the cron, with a per-commit gate); a failure files a ticket.

**Two runners**, via `test-runner: xcodebuild | swift | both`:
- `swift` — the **core internal Swift package** (`swift-package-path`): `swift test --enable-code-coverage`, with an optional `coverage-min` gate. This is where coverage is reported.
- `xcodebuild` — the **app/UI scheme** (`test-scheme`): unsigned `xcodebuild test` (XCTest + Swift Testing, app-hosted / UI).
- `both` runs both; a failure in **either** fails the run.

Results render on the **run page** via `$GITHUB_STEP_SUMMARY` (per-runner pass/fail + coverage %, no download); the `.xcresult` / coverage / `test-report.json` are uploaded as an artifact for deep dives. Failure tickets (beta + nightly) are filed into the board's **current active sprint** — needs `JIRA_*` vars + the `JIRA_API_TOKEN` secret (optional `JIRA_BOARD_ID`).

## Versioning of *this* repo

Pin caller `uses:` to a tag, not `@main`:

```yaml
uses: LeanBytes/workflows-macos/.github/workflows/distribute-pr.yml@v0.4.2
```

Patch versions (`v0.3.18`, `v0.3.19`, …) are the usual working unit — every workflow change ships under a new tag, and cross-callouts inside this repo plus `examples/per-app/` are bumped to that tag as part of the same commit. **`v0.4.0` is a breaking change** — product identity + changelog moved into per-product `Config/products/<id>.json`, shells became trigger-only, and release tags became `<id>-v*`; migrate a repo by creating its product files + swapping in the trigger-only shells when you bump it to `@v0.4.2`. Bump the tag in your callers when you want the change.

## Repo layout

```
.github/
  workflows/
    distribute-pr.yml          ← orchestrator (workflow_call)
    distribute-beta.yml        ← orchestrator (workflow_call)
    distribute-release.yml     ← orchestrator (workflow_call)
    _build-direct.yml          ← internal callee (workflow_call)
    _build-app-store.yml       ← internal callee (workflow_call)
    memory-watch.yml           ← reusable memory-leak watch (workflow_call)
    _test.yml                  ← reusable test runner (workflow_call)
    selftest.yml               ← lint + products.py offline tests (CI for this repo)
  scripts/
    products.py                ← discovery / plan-beta / plan-release brain
    build-direct.sh            ← shared Direct build core (CI + local both run this)
    changelog-from-json.sh     ← render Markdown notes from a product's inline .changelog
    update-appcast.sh          ← inject CDATA description + trim appcast.xml
    run-tests.sh               ← swift test / xcodebuild test core (+ coverage)
    memory_watch.py            ← sample RSS + leak verdict (exit 0/2/3)
    jira_client.py             ← shared Jira create + active-sprint placement
    create_jira_ticket.py      ← file a Jira issue on a detected leak
    create_test_ticket.py      ← file a Jira issue on a test failure
scripts/
  build-local.sh               ← run the Direct build on your Mac (wraps build-direct.sh)
examples/
  local-build.env.example      ← template for build-local.sh's env file
  per-app/
    distribute-pr.yml          ← copy to each app repo (trigger-only shells)
    distribute-beta.yml
    distribute-release.yml
    distribute-alpha.yml       ← optional manual invite-build shell
    nightly-memory-watch.yml   ← memory-watch caller shell
    nightly-tests.yml          ← nightly test caller shell
    Config/products/app.json   ← single-product sample
    two-product/               ← base + pro Config/products samples (FileFillet)
tests/
  run.sh + fixtures/           ← offline products.py suite
```

Versioning, beta-counting, and tag validation live in **`.github/scripts/products.py`** (`discover` / `plan-beta` / `plan-release`), called from the orchestrators' `prepare` / `discover` jobs and offline-tested via `tests/run.sh`.

## If you fork this repo private

The canonical repo at `LeanBytes/workflows-macos` is public; consumers don't need any extra access plumbing. If you fork it to a private repo for your own use, two extra permissions matter:

1. **Permission to *call* the workflows.** Set under your private fork's `Settings → Actions → General → Access`. Allow the consuming repos (or the whole org).
2. **Permission to *clone* the fork's scripts from inside the workflow.** The default `GITHUB_TOKEN` of a calling workflow is scoped to the calling repo only. Provide a token via a `SHARED_WORKFLOWS_TOKEN` secret on each consumer. The orchestrators **and** `_build-direct.yml` (which now clones `build-direct.sh`) reference it as `${{ secrets.SHARED_WORKFLOWS_TOKEN || github.token }}` — the orchestrators forward it to the build callee automatically, and everything falls back to `github.token` when the fork is public.

Quickest path — fine-grained PAT:

1. github.com → `Settings` → `Developer settings` → `Personal access tokens` → `Fine-grained tokens` → `Generate new token`
2. **Resource owner**: your org
3. **Repository access**: `Only select repositories` → your fork
4. **Permissions** → `Repository permissions` → `Contents`: **Read-only**
5. Add as `SHARED_WORKFLOWS_TOKEN` org secret on the consumers.

For longer-term hygiene, prefer a GitHub App: org-level, read-only `Contents` on your fork, installed on consumer repos, tokens minted at run-time via `actions/create-github-app-token`. No PAT rotation, no single-user dependency.

## License

MIT — see [LICENSE](LICENSE).
