# workflows-macos

Reusable GitHub Actions workflows for Apple app distribution: **iPhone and iPad** (App Store via TestFlight, and Ad Hoc for registered devices) and **Mac** (Developer ID Direct with Sparkle, and the Mac App Store via TestFlight). Drop them into any app repo that ships one or more of those channels.

> **Heads up — strongly opinionated.** These workflows are tailored to how Stephan Arenswald (personal) and **LeanBytes** ship apps. They power **MacPacker**, **FlowMoose**, **FileFillet** and the LeanBytes iPhone apps in production. The choices baked in — Developer ID + App Store driven from a single repo, Sparkle 2 with stable + beta channels, AWS S3 for direct-download hosting in `eu-central-1`, timestamp-based build numbers, provisioning profiles fetched from App Store Connect at build time, one self-contained `Config/products/<id>.json` per product (build identity + inline changelog) as the source of truth — reflect that specific use case. If your distribution model is different, expect to patch rather than just configure.

Adding a new app means: dropping one `Config/products/<id>.json` per product in your repo, setting the team's secrets once (certificates + one App Store Connect key) plus two S3 vars, creating one provisioning profile per bundle ID in the developer portal, and copying four **trigger-only** shell workflows into `.github/workflows/` (they *discover* your products — no `products` input). No build/sign/notarize/upload code lives in the consumer repo, and no provisioning profile is ever stored in GitHub.

> **v0.6.0 (breaking):** iOS joined (it used to live in `LeanBytes/workflows-ios`), the product file names its platforms, profiles come from App Store Connect, `distribute-beta.yml` became `distribute.yml`, and App Store builds no longer get tags. See [MIGRATING.md](MIGRATING.md) for every path from v0.3, v0.4, v0.5 and workflows-ios. Pin v0.6.1, not v0.6.0: until v0.6.1 (and v0.5.10), every tag checked out main's shared scripts instead of its own (#34).

## Architecture

```
Per-app shell (trigger-only)      Shared orchestrator                          Shared build callees
────────────────────────────      ──────────────────────────────────           ───────────────────────────
distribute-pr.yml          ──→   distribute-pr.yml                             (none — unsigned compile
  on: pull_request                  discover → compile every leg                 of every leg, inline)

distribute.yml             ──→   distribute.yml                          ┐
  on: push branches:[main]          prepare (plan) → build-* (matrix,     │    _build-ios.yml
  + manual "force"                  one job per callee) → publish         ├──→   .ipa (App Store, Ad Hoc)
                                                                          │
distribute-release.yml     ──→   distribute-release.yml                  │    _build-mac-store.yml
  on: push tags v* / <id>-v*        prepare (plan-release) → Direct leg   ├──→   .pkg (Mac App Store)
                                    → publish-release                     │
distribute-alpha.yml       ──→   distribute-alpha.yml                    │    _build-mac-direct.yml
  on: workflow_dispatch             prepare (plan-alpha) → every leg      ┘      notarized DMG + ZIP
                                    → publish-alpha (private)
```

A product names its **platforms** and the **channels** each ships through; `products.py` turns that into one **leg** per platform and channel. Each leg is built by the callee for its platform, which produces an **artifact**; the orchestrator's publish job decides the sequence, so a failure mid-way never half-publishes.

| Platform | Channel | Built by | Lands in |
|---|---|---|---|
| `ios` (iPhone, iPad) | `app-store` | `_build-ios.yml` | TestFlight → you submit it in App Store Connect |
| `ios` | `ad-hoc` | `_build-ios.yml` | IPA + manifest on S3, installed via `itms-services://` on registered devices |
| `macos` | `app-store` | `_build-mac-store.yml` | TestFlight → you submit it in App Store Connect |
| `macos` | `direct` | `_build-mac-direct.yml` | Notarized DMG/ZIP on S3, the Sparkle feed, a GitHub (pre-)release |

`tvos` and `visionos` are designed in (App Store only) and get switched on when the first app ships there; a product file naming them fails with "not supported yet".

## How versioning works (per-product, self-contained)

Each product is one **`Config/products/<id>.json`** in your app repo — its build identity plus an inline **`changelog`** object that is the source of truth for **that product's** next-to-ship version + release notes. The `changelog` value uses the schema below; your app loads it at runtime for its What's New view, and CI reads the same object for the appcast/Release notes — one author, one place, per product.

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

`comingNext` and each `item.title` are **locale-keyed maps** (`{"en": "...", "de": "..."}`). The shared workflows render the `en` value into the appcast description and GH Release body; the other locales are picked up by your app's in-product What's New view directly from the same file. `comingNext` is for the app UI only.

**Item types:** `feat` → New Features, `fix` → Bug Fixes, `core` → Improvements, `lang` → Localization, `release` → Announcements. `chore` is dropped silently (internal work); any other type is dropped too, but with a warning.

**Optional `issues` field.** Each item may carry an `"issues"` **array of strings** — the Jira keys (`"MP-417"`) and/or GitHub issues (`"#98"`) the change traces back to. It's pure provenance: the pipeline and the app's What's New view **ignore** it.

**Tags mark ship moments — of builds that reach customers on their own.** The **primary** product — the one that omits `id` — uses **bare `v*`** tags; every other product is prefixed `<id>-v*`. The prefix is a git/CI identifier only; `CFBundleShortVersionString` is always the bare `X.Y.Z`. At most one product per repo may omit `id`.
- `vX.Y.Z` / `<id>-vX.Y.Z` — the release. You push it by hand; CI validates it against that product's `changelog.versions[0].version`, builds the Direct leg (if there is one) for the stable Sparkle feed, and from then on builds nothing more of that version.
- `vX.Y.Z-beta.N` / `<id>-vX.Y.Z-beta.N` — the Nth Direct beta, auto-pushed on push→main. **Only a product with a Direct leg gets these**: a Direct beta reaches customers by itself, through the Sparkle beta feed.
- `vX.Y.Z-alpha.N` / `<id>-vX.Y.Z-alpha.N` — a manual alpha of a product with a Direct leg.
- **App Store and Ad Hoc builds get no tag.** TestFlight has no alpha/beta/release stages: every upload reaches your internal testers, and sending a build to external testers or the App Store is your choice per build in App Store Connect. The build you tested is the one you submit; nothing is rebuilt on the version tag.

**Marketing version per channel** (Apple's iTMS rejects non-`N.N.N` strings in `CFBundleShortVersionString`, so we split):
- **Direct / Sparkle:** `<next>-beta.<N>` for betas (e.g. `2.12.0-beta.4`), bare `<next>` for releases.
- **App Store, Ad Hoc:** bare `<next>` always; the timestamp build number tells builds apart.

**What builds on a push (the gate).** A product builds **only when** (a) its `changelog.versions[0]` version isn't released (no bare `<prefix><ver>` tag) AND (b) it changed — its own `Config/products/<id>.json` **or any of its `source-paths`**:
- **With a Direct leg:** since its last `-beta.N` tag, as before.
- **Without one:** since the commit the **last successful run** of `distribute.yml` on main built from — there are no tags to compare against, so the last good run takes their place. A failed run, a `[skip ci]` push, or a queued run GitHub cancelled for a newer one is therefore picked up by the next run, not lost. Listing the runs needs **`actions: read`** in the shell's `permissions` (the example has it); without it the run warns and compares against the push's previous commit only. The very first run, with no successful run before it, builds.

So editing only product A's changelog builds **only A**; a product at an already-released version is skipped (idle), never blocked. Start the next version by prepending a new `versions[0]` entry. **`force`** (a checkbox on the manual run) overrides "nothing changed", never "already released".

## Per-app setup

### 0. `Config/products/<id>.json` (one per product)

Drop one file per product in `Config/products/`. Each holds build identity, a **`platforms`** block and a **required** inline `changelog` whose `versions[0].version` MUST be set before any CI run can produce a build. Sample: [`examples/per-app/Config/products/app.json`](examples/per-app/Config/products/app.json).

```jsonc
// Config/products/app.json — an iPhone app that also ships on the Mac, on both Mac channels
{
  "id": "app",
  "product-name": "MyApp",
  "scheme": "MyApp",
  "bundle-id": "com.example.myapp",
  "platforms": {
    "ios":   { "app-store": {} },
    "macos": {
      "direct":    { "appcast": true },
      "app-store": { "scheme": "MyApp Store", "configuration": "Release Store" }
    }
  },
  "source-paths": ["MyApp/**", "Project.swift"],
  "changelog": { "versions": [ { "version": "1.0.0", "items": [] } ] }
}
```

Product-level fields (the defaults every leg inherits):

| Field | Meaning |
|---|---|
| `id` | Short unique key — labels the build/artifact, prefixes tags (`<id>-v*`). **Omit it** (or `""`) for the *primary* product → bare `v*` tags (≤1 per repo; a non-empty `id` must equal the filename). |
| `scheme` / `bundle-id` | Xcode scheme and the app's bundle ID. Required unless every leg sets its own. |
| `product-name` | The `.app`'s name — required for a Direct leg (it names the DMG/ZIP); elsewhere it defaults to the scheme and only labels the run summary. |
| `configuration` | Build configuration (default `Release`). |
| `platforms` | **Required.** `{"<platform>": {"<channel>": { …leg overrides… }}}` — see the table above for the pairs. An empty object means the product's defaults. |
| `source-paths` | **Recommended.** Git pathspecs this product builds from, e.g. `["MyApp/**", "Project.swift"]`. Without them only an edit to the product file counts as a change, so a code-only fix merges to `main`, builds nothing, and the run goes green with the fix unshipped; `plan` warns whenever it skips for that reason. |
| `changelog` | **Required.** Inline release notes (see *How versioning works*). |

Leg fields (inside `platforms.<platform>.<channel>`):

| Field | Legs | Meaning |
|---|---|---|
| `scheme`, `bundle-id`, `configuration`, `product-name` | all | What differs for this leg, e.g. a Mac App Store build with its own scheme, `.mas` bundle ID and `Release Store` configuration. |
| `distribute` | `app-store`, `ad-hoc` | `false` builds and signs the leg without uploading it (default `true`). |
| `appcast` | `direct` | `true` publishes to this product's Sparkle feed: betas as beta-channel items, releases as stable items. |
| `s3-subpath` | `direct` | S3 + appcast sub-prefix (e.g. `"pro"`; empty = the bucket root). |
| `appcast-filename` / `appcast-seed-path` | `direct` | This product's Sparkle feed filename + seed (defaults `appcast.xml` / `Config/appcast.xml`). |
| `changelog-filename` | `direct` | Name of the published `Changelog.json`. Give a second product at the **same** `s3-subpath` a distinct name (e.g. `Changelog-pro.json`). |
| `cert-secret` / `cert-password-secret` | all | Name of another certificate p12 + password secret for this leg (e.g. a legacy team kept after an account transfer). Default: the team's own. |

A key from the v0.5 format (`platform`, `build-app-store`, `scheme-store`, `has-finder`, `devid-profile-secret`, …) or from workflows-ios (`channel`, `profile-secret`, …) fails with a message naming what to use instead. Extensions need no key at all: every app and extension is signed with the profile for its own bundle ID.

For a two-product repo, copy the templates in [`examples/per-app/two-product/`](examples/per-app/two-product/).

### 1. Provisioning profiles — create them once, in the developer portal

CI never stores a profile. Every build job first downloads the team's **active** profiles of the type it needs (`IOS_APP_STORE`, `IOS_APP_ADHOC`, `MAC_APP_STORE` or `MAC_APP_DIRECT`) from the App Store Connect API, with the key the app already passes for uploads. At archive time each target — the app and each extension, widget or Watch app — looks up the profile for **its own bundle ID**; at export, every bundle in the archive is matched to its profile by bundle ID again. So:

- **Create one profile per bundle ID and channel** in the developer portal (any name). That's the whole setup; a new extension only needs its profile there.
- **Renewal:** regenerate the profile in the portal; the next build uses it.
- **The key must be allowed to read profiles.** The profile endpoints need an **Admin** App Store Connect key; a weaker key fails the first build step with `App Store Connect answered 403` and says so.
- A bundle with several active profiles of a type uses a hand-made one before an Xcode-managed one, then the latest expiry.

The download runs before any of the app's code (Tuist, SwiftPM plugins, the pre-build script), and the profiles it installed are removed again at the end of the job.

### 2. Secrets

Set once per team — as **organization** secrets for repos in an org; a personal account has no org secrets, so its repos hold copies.

| Secret | Purpose | Legs |
|---|---|---|
| `APPLE_DISTR_P12_BASE64` / `APPLE_DISTR_PASSWORD` | Apple Distribution cert + private key (base64) and its password — signs the app | `app-store`, `ad-hoc` |
| `MAC_DISTR_P12_BASE64` / `MAC_DISTR_PASSWORD` | Mac Installer Distribution cert + key — signs the `.pkg` | Mac `app-store` |
| `DEVELOPER_ID_P12_BASE64` / `DEVELOPER_ID_PASSWORD` | Developer ID Application cert + key | `direct` |
| `KEYCHAIN_PASSWORD` | Ephemeral build keychain password | all |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_BASE64` | App Store Connect API key (**Admin**) — downloads the profiles, uploads to TestFlight, notarizes | all |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | S3 upload credentials | `direct`, `ad-hoc` |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle EdDSA private key — one per app | `direct` with `"appcast": true` |
| `JIRA_API_TOKEN` | Files a ticket when gated tests fail | if `run-tests` |

Inside the build jobs each secret reaches **only the step that uses it** — the certificates the keychain step, the App Store Connect key the profile download (and notarization) — never a job-level environment that the app's own scripts could read.

### 3. Vars

Only repo-level **infrastructure** lives in Variables.

| Var | Purpose |
|---|---|
| `S3_DISTRIBUTION_PATH` | Full S3 URI for downloads, e.g. `s3://my-bucket/my-app` (Direct and Ad Hoc) |
| `S3_DOWNLOAD_URL` | Public HTTPS base URL for the same path (download links; the Ad Hoc manifest needs it) |
| `RUNS_ON_BUILD_IOS` | *(optional, temporary)* Override the runner for the iPhone/iPad archive — see below |
| `RUNS_ON_BUILD_MAC_STORE` | *(optional, temporary)* Override the runner for the Mac App Store archive |
| `RUNS_ON_BUILD_MAC_DIRECT` | *(optional, temporary)* Override the runner for the Developer ID archive |
| `RUNS_ON_TEST` | *(optional, temporary)* Override the runner for the test job |
| `RUNS_ON_BUILD` | *(optional, temporary)* Override the runner for the PR compile job |
| `RUNS_ON_PUBLISH` | *(optional, temporary)* Override the runner for the publish job |
| `RUNS_ON_DISCOVER` | *(optional, temporary)* Override the runner for the PR discover job |
| `RUNS_ON_PREPARE` | *(optional, temporary)* Override the runner for the distribute/release/alpha prepare job |

#### Moving a job off the self-hosted Mac

The per-app shell's `runs-on-*` inputs are the standing answer to where a job runs. The `RUNS_ON_*` Variables above are the temporary one: each overrides the matching input, so a job can be moved without a commit to the app repo, and moved back by deleting the variable.

```
Repo → Settings → Secrets and variables → Actions → Variables
  RUNS_ON_BUILD_MAC_STORE = macos-26
```

The next run's Mac App Store archive goes to a GitHub-hosted `macos-26` image; the other jobs stay wherever the shell put them. Delete the variable and the next run is back to the input. Nothing is baked in — the override is read fresh on every run.

The case this exists for: a self-hosted Mac on a beta Xcode. `notarytool` accepts a bundle built with one, so the Direct channel keeps working, but `altool` rejects it (error 90301), so every App Store upload fails until Apple ships the release Xcode. The same knob covers a Mac that is down, upgrading, or busy.

Unlike the `runs-on-*` inputs, these take a **bare label** (`macos-26`), not JSON — a Variable is typed into a text box, so requiring `"macos-26"` with the quotes would be a footgun for no gain. An unset variable is `''`, which is falsy, so a repo that sets none behaves exactly as before.

**Pin `prepare` / `discover` too, or nothing runs.** These are the coordination jobs, and they go first — every build, test and publish job `needs:` one of them. A repo with no self-hosted runner that pins only the build inputs still deadlocks on the very first job, and it deadlocks *silently*: a job waiting for a runner that does not exist stays `queued` and never turns red. The two `gate` jobs need no variable of their own — each follows the job it gates.

**One runner process per macOS user.** Signing uses an ephemeral keychain and the user's keychain search list, which are per macOS user, not per job. Two jobs signing at once under the same user would take each other's keychain away — so run one runner process per macOS user on a self-hosted Mac (legs of one run then build one after the other).

### 4. Per-app xcconfig

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

Your `Info.plist` must reference `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)`. Signing settings in the project don't matter to CI: it archives with manual signing, the team's distribution identity, and the profile each target looks up by bundle ID.

### 5. Drop in the four shell workflows

Copy from [`examples/per-app/`](examples/per-app/) — the same files serve every app; which legs exist is the product file's job:

- `distribute-pr.yml` — every PR: unsigned compile of every leg.
- `distribute.yml` — every push to main (and by hand with `force`).
- `distribute-release.yml` — your version tag.
- `distribute-alpha.yml` — by hand, from any branch.

Pin the `uses:` line to a tag (`@v0.6.1`), not `@main`. Uncomment per-app inputs as needed.

**On secret passing.** GitHub Actions' `secrets: inherit` only crosses repository boundaries *within the same org/enterprise*, and it hands the shared workflow every secret the repo can see. The example shells list each secret explicitly, which works in every configuration and passes only what is used. Keep that block as-is.

**Per-app build flags:** `use-tuist` (Xcode project generated by Tuist), `lfs` (pull git LFS files on the build checkouts — e.g. FlowMoose's Whisper model), `extra-xcodebuild-args` (build settings appended to the archive — not for signing), `products-dir` (default `Config/products`), `artifact-retention-days` (default `7` in a private repo; a **public** repo keeps build artifacts one day, since anyone signed in to GitHub can download them).

**Release trigger.** The primary product releases via bare `vX.Y.Z`, other products via `<id>-vX.Y.Z`. Your `distribute-release.yml` shell matches **both** and excludes the beta + alpha tags of either:

```yaml
on:
  push:
    tags:
      - 'v[0-9]*'     # primary product:  v2.12.0
      - '*-v[0-9]*'   # other products:   pro-v1.1.1
      - '!*-beta.*'
      - '!*-alpha.*'
```

For a product without a Direct leg, the release run only checks the tag and builds nothing — submit the build you tested in App Store Connect.

**GH (pre-)release titles + assets.** The title matches the tag. By default a Direct build's DMG + ZIP are attached to its release; set **`attach-release-assets: false`** to skip that and **save GitHub storage/bandwidth** — the DMG/ZIP still go to S3 (where the appcast points).

**GitHub Discussions (off by default, releases only).** Set `create-discussion: true` in `distribute-release.yml`'s shell to auto-open a discussion alongside each stable release; the category defaults to `Announcements` (`discussion-category: <name>` overrides it). The orchestrator passes `--discussion-category` to `gh release create` as one atomic call, so if the discussion API errors, **no release is created**. Before turning it on, check that Discussions are enabled, a category with the **exact** name exists, and the shell grants `discussions: write` — a misleading `HTTP 404: Discussion could not be created` covers all three.

**Alpha / invite builds (manual).** To hand a rough, early build to a hand-picked few — e.g. work on a `3.0` branch — run "Distribute Alpha" from the Actions tab on that branch. It builds every leg of the product, signed like a release:
- **App Store legs** go to TestFlight as **internal-only** builds (`testFlightInternalTestingOnly`): App Store Connect keeps them from external testers and the App Store.
- **Direct and Ad Hoc legs** go to an **unlisted `alpha/<label>/` prefix** on S3; the run summary prints the links. No appcast, no `Changelog.json`, no GitHub Release.
- A product with a Direct leg is tagged `<prefix><base>-alpha.<N>` (`<base>` = its `changelog.versions[0].version` or the `version-base` input; `<N>` counted from existing alpha tags). **Exclude alpha tags from your release trigger** (shown above).
- `product-id` may stay empty when the repo has one product. The shell must live on your **default branch** (for the "Run workflow" button) *and* on the branch you build.

### 6. Build hooks (app-specific setup and checks)

For apps that need extra setup on the build runner (asset downloads, codegen, etc.), every build callee exposes `pre-build-cache-*` + `pre-build-script` inputs. The script lives in the consumer repo, so no app-specific paths or URLs leak into the shared workflow.

There is a matching **`post-build-script`** on every build path. It is called with the built **`.app` bundle as `$1`**, and a non-zero exit fails the job. Use it to inspect what was produced: architecture slices, bundle contents, embedded extensions, entitlements.

```yaml
      post-build-script: scripts/check-architectures.sh
```

`$1` is always a `.app`, never a `.pkg` or `.ipa`, so one script serves every leg. On the distribution paths it runs against the app **inside the archive**, right after `Archive` — the only artifact every leg shares — so it fails before notarization and upload rather than after. On a PR it runs after the unsigned compile, against the product in DerivedData.

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

## Migrating

[MIGRATING.md](MIGRATING.md) takes an app to v0.6.1 from v0.5.x, v0.4.x, v0.3.x or `LeanBytes/workflows-ios`. It covers:

- every retired product-file key and shell input, with its replacement
- before and after files for a Direct + App Store app with extensions
- which secrets to delete and which the App Store Connect key now needs
- the renamed runner inputs and variables
- how an App Store build now reaches review
- a one-line fix for apps still pinned to v0.5.9 or older

## Local builds (no CI)

Need a signed + notarized DMG/ZIP to test a fix — without burning a commit and a CI run? `scripts/build-local.sh` runs the **exact same** Direct pipeline `_build-mac-direct.yml` runs (same profile download, ephemeral keychain from your base64 cert, same `xcodebuild` / `notarytool` / `ditto` commands, same Gatekeeper verification) on your Mac. The workflow and the script both call one shared core — `.github/scripts/build-direct.sh` — so they can't drift.

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

`distribute.yml` enforces strict sequencing in its publish job:

```
1. Render release notes from each product's inline .changelog
2. (gate) altool → App Store Connect    every app-store leg with distribute (iPhone and Mac)
3. aws s3 cp IPA + manifest.plist       every ad-hoc leg — live at once
4. aws s3 cp DMG/ZIP                    every direct leg (silent — no Sparkle client polls these yet)
5. (gate) beta appcast update           every direct leg with "appcast": true
6. per Direct product: git push <prefix><ver>-beta.N + gh release create --prerelease
```

`distribute-release.yml` does steps 1, 4, the product's `Changelog.json` to S3, the stable appcast, and the GitHub Release last. The appcast update is the "go-live" moment for Sparkle clients; the GH (pre-)release is created last. A failure anywhere short-circuits the rest, so you never end up with a half-published version — and a build job that failed or was cancelled stops the publish job altogether.

## Memory-leak watch

A reusable workflow ([`memory-watch.yml`](.github/workflows/memory-watch.yml)) that builds a Mac app **unsigned**, runs it for hours on a runner, and samples its resident memory to catch leaks (unbounded growth). It reuses this repo's build knowledge — Tuist install/generate, runner selection, the `.shared-ci` script sharing — so a calling app sets only a few inputs; no signing, no release machinery.

Outcome semantics are deliberate — **a leak is a successful watch**:
- healthy → job success
- leak detected → file a Jira ticket (when `file-jira-on-leak`) → job **success**
- infra/watch error (build failed, app wouldn't launch, the watcher crashed) → job **fail**

`memory_watch.py` samples RSS via `ps`, applies a hard cap plus a slope-and-floor trend rule after a warmup window, and exits `0` (healthy) / `2` (leak) / `3` (error). Drop in the [`examples/per-app/nightly-memory-watch.yml`](examples/per-app/nightly-memory-watch.yml) shell (it owns the cron), point `runs-on` at a runner (**multi-hour watches need self-hosted** — GitHub-hosted macOS caps a job at 6h), and optionally wire Jira (`JIRA_*` vars + `JIRA_API_TOKEN`). A per-commit cache gate watches each commit on `main` exactly once.

## Testing

Run an app's Swift tests at three points — all **opt-in** per app via `run-tests`. The logic is one reusable workflow ([`_test.yml`](.github/workflows/_test.yml)) wrapping one shared script ([`run-tests.sh`](.github/scripts/run-tests.sh)):

- **On PRs** (`distribute-pr.yml`, `run-tests: true`) — a failure turns the PR check **red** (no ticket — the author fixes before merge). The unsigned compile of every leg runs either way.
- **On merge** (`distribute.yml`, `run-tests: true`) — tests **gate** the build: if they fail, nothing is built or published, the workflow fails, and a Jira ticket is filed.
- **Nightly** — drop in [`examples/per-app/nightly-tests.yml`](examples/per-app/nightly-tests.yml) (it owns the cron, with a per-commit gate); a failure files a ticket.

**Two runners**, via `test-runner: xcodebuild | swift | both`:
- `swift` — the **core internal Swift package** (`swift-package-path`): `swift test --enable-code-coverage`, with an optional `coverage-min` gate. This is where coverage is reported.
- `xcodebuild` — the **app/UI scheme** (`test-scheme`): unsigned `xcodebuild test` (XCTest + Swift Testing, app-hosted / UI) on `test-destination` — by default the Mac when the first product has a Mac leg, else an iOS Simulator (`platform=iOS Simulator,name=iPhone 17`).
- `both` runs both; a failure in **either** fails the run.

Results render on the **run page** via `$GITHUB_STEP_SUMMARY` (per-runner pass/fail + coverage %, no download); the `.xcresult` / coverage / `test-report.json` are uploaded as an artifact for deep dives. Failure tickets are filed into the board's **current active sprint** — needs `JIRA_*` vars + the `JIRA_API_TOKEN` secret (optional `JIRA_BOARD_ID`).

## Versioning of *this* repo

Pin caller `uses:` to a tag, not `@main`:

```yaml
uses: LeanBytes/workflows-macos/.github/workflows/distribute.yml@v0.6.1
```

Patch versions are the usual working unit — every workflow change ships under a new tag, and cross-callouts inside this repo plus `examples/per-app/` are bumped to that tag as part of the same commit. **`v0.6.0` is a breaking change** (see [Migrating](MIGRATING.md)); so was `v0.4.0`, which moved product identity + changelog into `Config/products/<id>.json`.

## Repo layout

```
.github/
  workflows/
    distribute-pr.yml          ← orchestrator: PR compile of every leg
    distribute.yml             ← orchestrator: push to main
    distribute-release.yml     ← orchestrator: version tag (Direct release)
    distribute-alpha.yml       ← orchestrator: manual private alpha
    _build-ios.yml             ← callee: iPhone/iPad .ipa (App Store, Ad Hoc)
    _build-mac-store.yml       ← callee: Mac App Store .pkg
    _build-mac-direct.yml      ← callee: notarized Mac DMG + ZIP
    _test.yml                  ← reusable test runner (workflow_call)
    memory-watch.yml           ← reusable memory-leak watch (workflow_call)
    selftest.yml               ← lint + offline tests (CI for this repo)
  scripts/
    products.py                ← discover / plan / plan-release / plan-alpha brain
    profiles.py                ← provisioning profiles from App Store Connect: fetch, archive args, ExportOptions
    build-direct.sh            ← shared Direct build core (CI + local both run this)
    classify-upload.sh         ← one definition of "did the altool upload land?"
    manifest.sh                ← the Ad Hoc itms-services manifest
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
    distribute.yml
    distribute-release.yml
    distribute-alpha.yml
    nightly-memory-watch.yml   ← memory-watch caller shell
    nightly-tests.yml          ← nightly test caller shell
    Config/products/app.json   ← single-product sample (iPhone + both Mac channels)
    two-product/               ← base + pro Config/products samples (FileFillet)
tests/
  run.sh + fixtures/           ← offline suite: products.py, profiles.py, workflow wiring
```

## If you fork this repo private

The canonical repo at `LeanBytes/workflows-macos` is public; consumers don't need any extra access plumbing. If you fork it to a private repo for your own use, two extra permissions matter:

1. **Permission to *call* the workflows.** Set under your private fork's `Settings → Actions → General → Access`. Allow the consuming repos (or the whole org).
2. **Permission to *clone* the fork's scripts from inside the workflow.** The default `GITHUB_TOKEN` of a calling workflow is scoped to the calling repo only. Provide a token via a `SHARED_WORKFLOWS_TOKEN` secret on each consumer. Every `.shared-ci` checkout references it as `${{ secrets.SHARED_WORKFLOWS_TOKEN || github.token }}` — the orchestrators forward it to the build callees, and everything falls back to `github.token` when the repo is public.

Quickest path — fine-grained PAT:

1. github.com → `Settings` → `Developer settings` → `Personal access tokens` → `Fine-grained tokens` → `Generate new token`
2. **Resource owner**: your org
3. **Repository access**: `Only select repositories` → your fork
4. **Permissions** → `Repository permissions` → `Contents`: **Read-only**
5. Add as `SHARED_WORKFLOWS_TOKEN` org secret on the consumers.

For longer-term hygiene, prefer a GitHub App: org-level, read-only `Contents` on your fork, installed on consumer repos, tokens minted at run-time via `actions/create-github-app-token`. No PAT rotation, no single-user dependency.

## License

MIT — see [LICENSE](LICENSE).
