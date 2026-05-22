# workflows-macos

Reusable GitHub Actions workflows for macOS app distribution — Developer ID Direct (Sparkle) + App Store (TestFlight / App Store Connect). Drop them into any macOS app repo that ships either or both channels.

> **Heads up — strongly opinionated.** These workflows are tailored to how Stephan Arenswald (personal) and **LeanBytes** ship macOS apps. They power **MacPacker**, **FlowMoose**, and **FileFillet** in production. The choices baked in — Developer ID + App Store driven from a single repo, Sparkle 2 with stable + beta channels, AWS S3 for direct-download hosting in `eu-central-1`, timestamp-based build numbers, `Config/Changelog.json` as the single source of truth for versioning and release notes — reflect that specific use case. If your distribution model is different, expect to patch rather than just configure.

Adding a new app means: dropping a curated `Config/Changelog.json` in your repo, setting ~9 secrets + ~5 vars, and copying three thin shell workflows into `.github/workflows/`. No build/sign/notarize/upload code lives in the consumer repo.

## Architecture

```
Per-app shell (event-triggered)             Shared orchestrator                  Shared callees
─────────────────────────────              ─────────────────────────            ──────────────────────────
.github/workflows/distribute-pr.yml ──→    distribute-pr.yml                  ┐
  on: pull_request                           prepare → build-direct → publish ─┤
                                                                               │
distribute-beta.yml             ──→        distribute-beta.yml                 │   _build-direct.yml
  on: pull_request closed (merged)           prepare → build-direct +      ────┼──→  (artifact: direct-build)
                                             build-app-store → publish-beta    │
                                             → push v<next>-beta.<N> tag       │   _build-app-store.yml
distribute-release.yml          ──→        distribute-release.yml              ┘    (artifact: app-store-build)
  on: push tags v*.*.*                       prepare → validate tag matches
       (excluding v*-beta.*)                 Changelog.json → build-* →
                                             publish-release
```

The build callees produce **artifacts** (DMG/ZIP for Direct, `.pkg` for App Store). Orchestrators decide the publishing sequence so failure mid-channel doesn't half-publish.

## How versioning works (the single source of truth)

`Config/Changelog.json` in **your app repo** is the source of truth for the next-to-ship version and the customer-facing release notes. The same file feeds the in-app "What's New" view and the appcast/release notes — one author, one place.

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
        {"type": "feat", "title": {"en": "Show folder color from macOS 26 Tahoe"}},
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

**Tags mark ship moments:**
- `vX.Y.Z` — stable release. You push this manually when ready.
- `vX.Y.Z-beta.N` — Nth beta of in-progress `X.Y.Z`. Auto-pushed by the beta workflow on every PR merge.

**Marketing version per channel** (Apple's iTMS rejects non-`N.N.N` strings in `CFBundleShortVersionString`, so we split):
- **Direct / Sparkle:** `<next>-beta.<N>` for betas (e.g. `2.12.0-beta.4`), bare `<next>` for releases.
- **App Store / TestFlight:** bare `<next>` always; the build number disambiguates.

**Safeguard.** If `versions[0].version` already has a corresponding `v<X.Y.Z>` tag (i.e. you shipped that version, but haven't yet prepended a new entry for the next one), the PR workflow's `prepare` step fails the PR check with an actionable error. You add a new `versions[0]` entry to your PR, the check goes green, and the merge produces the first beta of the new version. Commits and merges are never blocked by this — only the auto-publish work refuses to run against stale state.

## Per-app setup

### 0. `Config/Changelog.json`

Drop this file in your app repo. Empty `versions` is fine to start, but `versions[0].version` MUST be set before any CI run can produce a build. Your app code should load this file at runtime for its What's New view; CI reads the same file for release notes and version derivation.

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

| Var | Purpose |
|---|---|
| `SCHEME_NAME` | Xcode scheme for Direct build |
| `SCHEME_NAME_STORE` | Xcode scheme for App Store build (only if you ship App Store) |
| `BUNDLE_ID` | Main app bundle ID |
| `BUNDLE_ID_FINDER`, `BUNDLE_ID_QUICKLOOK` | Extension bundle IDs (only if extensions present) |
| `PRODUCT_NAME` | `.app` filename without extension |
| `S3_DISTRIBUTION_PATH` | Full S3 URI for direct downloads, e.g. `s3://my-bucket/my-app` |
| `S3_DOWNLOAD_URL` | Public base URL for the same path (PR comment links) |

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

Pin the `uses:` line to a tag (`@v0.3.31`), not `@main`. Uncomment per-app inputs as needed.

**On secret passing.** GitHub Actions' `secrets: inherit` only crosses repository boundaries *within the same org/enterprise*. If your consumer repo lives in the **same org** as `LeanBytes/workflows-macos` (i.e. the `LeanBytes` org), you can simplify the shell to:

```yaml
jobs:
  pr:
    uses: LeanBytes/workflows-macos/.github/workflows/distribute-pr.yml@v0.3.31
    secrets: inherit
    with:
      # …
```

If your consumer repo is in a **different account or org** (a personal account, a different org, a fork without an enterprise tie), `secrets: inherit` silently passes nothing — every signing step then fails with a `security: SecKeychainItemImport` error. The example shells use the explicit `secrets:` block that works universally. Keep that block as-is unless you want the same-org shortcut.

The beta and release orchestrators expose four independent toggles for build/distribute control:

| Input | Default | Effect |
|---|---|---|
| `build-direct` | `true` | Build the .app/DMG/ZIP via `_build-direct.yml` |
| `build-app-store` | `false` | Build the .pkg via `_build-app-store.yml` |
| `distribute-app-store` | `false` | altool upload to ASC. Requires `build-app-store`. |
| `distribute-beta-appcast` *(beta only)* | `false` | Publish to the Sparkle beta channel. Requires `build-direct`. |
| `distribute-stable-appcast` *(release only)* | `true` | Publish to the Sparkle stable channel. Requires `build-direct`. |

Common configurations:

- **Direct-only, Sparkle stable + beta channels.** `build-direct: true`, `distribute-beta-appcast: true` in the beta shell, `distribute-stable-appcast: true` in the release shell (the default).
- **Direct + App Store, no beta appcast.** `build-direct: true`, `build-app-store: true`, `distribute-app-store: true`. Beta builds go to TestFlight (not the Sparkle beta channel); stable releases go to both Sparkle stable and the App Store.
- **App Store only.** `build-direct: false`, `build-app-store: true`, `distribute-app-store: true`, `distribute-stable-appcast: false`.

Per-app build flags also available: `use-tuist` (if your Xcode project is generated by Tuist), `has-finder-extension` / `has-quicklook-extension` (each gates an extra provisioning profile + bundle ID), `extra-xcodebuild-args`, `changelog-path` (defaults to `Config/Changelog.json`).

**Release trigger.** Your `distribute-release.yml` shell must exclude the auto-pushed beta tags so they don't fire the stable flow:

```yaml
on:
  push:
    tags:
      - 'v*.*.*'
      - '!v*-beta.*'
```

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

## Publish ordering

Both `distribute-beta.yml` and `distribute-release.yml` enforce strict sequencing in their publish job:

```
1. Render release notes from Config/Changelog.json
2. (gate) altool → ASC          if distribute-app-store
3. aws s3 cp DMG/ZIP             (silent — no Sparkle client polls these without an appcast pointer)
4. (gate) appcast.xml update     if distribute-beta-appcast / distribute-stable-appcast
5. (beta only) git push origin v<next>-beta.<N>
6. gh release create             ← only if 1-5 all succeeded
```

Step 4 is the "go-live" moment for Sparkle clients. Step 6 publishes the GH Release (pre-release for betas, full release for stable). A failure anywhere short-circuits the rest, so you never end up with a half-published version.

## Versioning of *this* repo

Pin caller `uses:` to a tag, not `@main`:

```yaml
uses: LeanBytes/workflows-macos/.github/workflows/distribute-pr.yml@v0.3.18
```

Patch versions (`v0.3.18`, `v0.3.19`, …) are the working unit — every workflow change ships under a new patch tag, and cross-callouts inside this repo plus `examples/per-app/` are bumped to that tag as part of the same commit. Bump the tag in your callers when you want the change.

## Repo layout

```
.github/
  workflows/
    distribute-pr.yml          ← orchestrator (workflow_call)
    distribute-beta.yml        ← orchestrator (workflow_call)
    distribute-release.yml     ← orchestrator (workflow_call)
    _build-direct.yml          ← internal callee (workflow_call)
    _build-app-store.yml       ← internal callee (workflow_call)
  scripts/
    changelog-from-json.sh     ← render Markdown notes from Config/Changelog.json
    update-appcast.sh          ← inject CDATA description + trim appcast.xml
examples/
  per-app/
    distribute-pr.yml          ← copy to each app repo
    distribute-beta.yml
    distribute-release.yml
```

Versioning, beta-counting, and tag validation all live **inline** in the orchestrator workflows — there's no `version-derive.sh` (deleted in v0.3.18). See the prepare-job steps in `distribute-{pr,beta,release}.yml` for the actual logic.

## If you fork this repo private

The canonical repo at `LeanBytes/workflows-macos` is public; consumers don't need any extra access plumbing. If you fork it to a private repo for your own use, two extra permissions matter:

1. **Permission to *call* the workflows.** Set under your private fork's `Settings → Actions → General → Access`. Allow the consuming repos (or the whole org).
2. **Permission to *clone* the fork's scripts from inside the workflow.** The default `GITHUB_TOKEN` of a calling workflow is scoped to the calling repo only. Provide a token via a `SHARED_WORKFLOWS_TOKEN` secret on each consumer (the orchestrators reference it as `${{ secrets.SHARED_WORKFLOWS_TOKEN || github.token }}` and fall back automatically when the fork is public).

Quickest path — fine-grained PAT:

1. github.com → `Settings` → `Developer settings` → `Personal access tokens` → `Fine-grained tokens` → `Generate new token`
2. **Resource owner**: your org
3. **Repository access**: `Only select repositories` → your fork
4. **Permissions** → `Repository permissions` → `Contents`: **Read-only**
5. Add as `SHARED_WORKFLOWS_TOKEN` org secret on the consumers.

For longer-term hygiene, prefer a GitHub App: org-level, read-only `Contents` on your fork, installed on consumer repos, tokens minted at run-time via `actions/create-github-app-token`. No PAT rotation, no single-user dependency.

## License

MIT — see [LICENSE](LICENSE).
