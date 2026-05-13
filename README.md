# workflows-macos

Reusable GitHub Actions workflows for macOS app distribution — Direct (Sparkle) + App Store (TestFlight / App Store Connect). Used by every macOS app under the **LeanBytes** org.

Adding a new app means setting ~7 secrets + ~4 vars in the app repo and dropping three thin shell workflows into `.github/workflows/`. No build/sign/notarize/upload code lives in the consuming repo.

## Architecture

```
Per-app shell (event-triggered)             Shared orchestrator                 Shared callees
─────────────────────────────              ─────────────────────────           ──────────────────────────
.github/workflows/distribute-pr.yml ──→    distribute-pr.yml                ┐
  on: pull_request                           prepare → build-direct → publish─┤
                                                                              │
distribute-beta.yml             ──→        distribute-beta.yml                │   _build-direct.yml
  on: pull_request closed (merged)           prepare → build-direct + ────────┼──→  (artifact: direct-build)
                                             build-app-store → publish-beta   │
                                                                              │   _build-app-store.yml
distribute-release.yml          ──→        distribute-release.yml             ┘    (artifact: app-store-build)
  on: push tags v*.*.*                       prepare → build-direct +
                                             build-app-store → publish-release
```

Build callees produce **artifacts** (DMG/ZIP for direct, .pkg for App Store). Orchestrators control the publishing sequence so we can fail-safe between channels — if App Store fails, the appcast doesn't move, and no one downloads a partly-published release.

## Publish ordering

Both `distribute-beta.yml` and `distribute-release.yml` enforce strict sequencing in their publish job:

```
1. (gate) altool → ASC          if enable-app-store
2. aws s3 cp DMG/ZIP             (silent — no Sparkle client polls these URLs without an appcast pointer)
3. (gate) appcast.xml update     if publish-appcast / publish-beta-appcast
4. gh release create             ← only if 1-3 all succeeded
```

Step 1 is the App Store gate. Step 3 is the "go-live" moment for Sparkle clients. Step 4 publishes the GH Release. A failure anywhere short-circuits the rest.

The release notes are fetched **before** any publishing via the GitHub API's `generate-notes` endpoint (returns Markdown without creating a Release object), then optionally enriched via Jira, then injected into appcast `<description>` CDATA, then embedded in the final `gh release create`.

## Per-app setup

### 1. Secrets

Set in your app's repo (or inherit from org):

| Secret | Purpose | Required for |
|---|---|---|
| `DEVELOPER_ID_P12_BASE64` | Developer ID p12 (base64) | Direct (always) |
| `CERTIFICATE_PASSWORD` | Password for above p12 | Direct |
| `KEYCHAIN_PASSWORD` | Ephemeral build keychain password | Both |
| `PROV_PROF_DEVID_BASE64` | Main Developer ID provisioning profile | Direct |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_BASE64` | App Store Connect API key | Both (notarization + altool) |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | S3 upload credentials | Direct |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle EdDSA private key | Direct (appcast signing) |
| `APP_STORE_P12_BASE64`, `APP_STORE_CERT_PASSWORD` | Apple Distribution cert | App Store |
| `PROV_PROF_STORE_BASE64` | Main App Store provisioning profile | App Store |
| `PROV_PROF_DEVID_FINDER_BASE64`, `PROV_PROF_STORE_FINDER_BASE64` | Finder extension profiles | macpacker |
| `PROV_PROF_DEVID_QL_BASE64`, `PROV_PROF_STORE_QL_BASE64` | Quick Look extension profiles | macpacker |
| `JIRA_USER_EMAIL`, `JIRA_API_TOKEN` | Jira changelog enrichment (optional) | Apps that want it |

### 2. Vars

| Var | Purpose |
|---|---|
| `SCHEME_NAME` | Xcode scheme for Direct build |
| `SCHEME_NAME_STORE` | Xcode scheme for App Store build |
| `BUNDLE_ID` | Main app bundle ID |
| `BUNDLE_ID_FINDER`, `BUNDLE_ID_QUICKLOOK` | Extension bundle IDs (macpacker) |
| `PRODUCT_NAME` | `.app` filename without extension |
| `S3_DISTRIBUTION_PATH` | Full S3 URI (e.g. `s3://leanbytes/flowmoose`) |
| `S3_DOWNLOAD_URL` | Public base URL for the same path (PR comment links) |
| `JIRA_BASE_URL` | e.g. `https://sarensw.atlassian.net` (if using Jira enrich) |
| `JIRA_KEY_PREFIX` | Default `LB`. Override if your project uses a different prefix |

### 3. Per-app xcconfig

Two app-side requirements that this workflow does NOT handle for you:

```
// Config/Release.xcconfig — required for App Store apps to skip ASC's
// manual export-compliance review on every TestFlight upload
INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO
```

```
// Config/Version.xcconfig — only the placeholder for local debug builds.
// CI overrides MARKETING_VERSION via xcodebuild at archive time.
MARKETING_VERSION = 0.0.0-dev
```

Your `Info.plist` (auto-generated or static) must reference `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)`.

### 4. Drop in the three shells

Copy from `examples/per-app/`:

- `distribute-pr.yml`
- `distribute-beta.yml`
- `distribute-release.yml`

Uncomment per-app inputs (use-tuist, enable-app-store, has-finder-extension, etc.) as needed. Reference table:

| App | use-tuist | cache-whisper-model | enable-app-store | publish-beta-appcast | has-finder-extension | has-quicklook-extension |
|---|---|---|---|---|---|---|
| FlowMoose | ✓ | ✓ | — | ✓ | — | — |
| filefillet | — | — | ✓ | — | — | — |
| macpacker | — | — | ✓ | — | ✓ | ✓ |

## Versioning

Pin caller `uses:` to a tag (`@v0.1`), not `@main`:

```yaml
uses: LeanBytes/workflows-macos/.github/workflows/distribute-pr.yml@v0.1
```

Patch versions (`v0.1.1`, `v0.1.2`, …) for bug fixes — bump the tag in your callers when you want them. Minor/major versions for breaking changes — review the changelog before bumping.

`distribute-pr.yml` (and the other orchestrators) call `_build-direct.yml` via the relative `./.github/workflows/_build-direct.yml` path, so the callee version is automatically pinned to whatever the orchestrator was called as.

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
    version-derive.sh          ← derive version from git tags
    release-notes-fetch.sh     ← GH auto-notes API wrapper (no Release created)
    enrich-changelog-with-jira.sh  ← optional Jira summary substitution
    update-appcast.sh          ← inject notes + trim appcast.xml
examples/
  per-app/
    distribute-pr.yml          ← copy to each app repo
    distribute-beta.yml
    distribute-release.yml
workflows/                     ← reference snapshots from filefillet/flowmoose/macpacker
                                 (will be removed once all three are migrated)
```

## Access for private consumers

This repo is private. For private consumer repos to call its workflows, ensure under `Settings → Actions → General → Access` the access policy includes the consuming repos (or the whole `LeanBytes` org).
