# Migrating to v0.6.3

v0.6 changes four things an app repo holds:

- the product file
- the shell workflows
- the secrets
- the runner variables

This guide takes an app from any earlier line to **v0.6.3**. Find your starting point in the `uses:` line of your shells (`…/distribute-beta.yml@v0.5.9` means v0.5).

| You are on | Go to |
|---|---|
| `LeanBytes/workflows-macos` v0.5.x | [From v0.5](#from-v05) |
| `LeanBytes/workflows-macos` v0.4.x (latest v0.4.9) | [From v0.4](#from-v04), then the v0.5 steps |
| `LeanBytes/workflows-macos` v0.3.x (latest v0.3.50) | [From v0.3](#from-v03), then the v0.5 steps |
| `LeanBytes/workflows-ios`, any version | [From workflows-ios](#from-workflows-ios) |

**Pin v0.6.3, never v0.6.0.** Before v0.6.1 and v0.5.10, every tag checked out main's shared scripts instead of its own ([#34](https://github.com/LeanBytes/workflows-macos/issues/34)), and before v0.6.2 and v0.5.11 no Tuist install honored the app's pin ([#39](https://github.com/LeanBytes/workflows-macos/issues/39)).

## Broken since 2026-10-21? Unbreak first

Every shell pinned to v0.5.9 or older runs main's scripts. Since v0.6 landed on main, those runs fail in `discover`/`prepare` with errors like `'platform' was retired in v0.6`. If you can't migrate yet:

- **v0.5.x:** change every `@v0.5.N` in your shells to `@v0.5.11`. Nothing else changes, except for a Tuist app (below).
- **v0.4.x:** move to `@v0.5.11` as well, and replace `runs-on-build`:
  - beta and release shells: `runs-on-build-direct` and `runs-on-build-store`, with the same value for both.
  - alpha shell: `runs-on-build-direct`.
  - The PR shell keeps `runs-on-build`.
- **v0.3.x:** there is no quick fix. v0.4 introduced the product files, so migrate to v0.6.3 straight away.
- **Tuist app (`use-tuist: true`), any line:** since 2026-10-22 the Tuist install fails with `no versions found for tuist`. v0.5.11 and v0.6.2 install the version the app pins, so commit a `mise.toml` at the repo root if it has none:

  ```toml
  [tools]
  tuist = "4.195.16"   # the version `tuist version` prints for you
  ```

  A pin you already have works as it is. A `[tool_alias.tuist.versions]` block that maps `latest` to the pin is no longer needed.

## Before you start (every path)

1. **Profiles exist in the developer portal**, one per bundle ID and channel: the app and every extension, widget or Watch app.
   - Mac: Developer ID (`MAC_APP_DIRECT`) for a `direct` leg, Mac App Store (`MAC_APP_STORE`) for an `app-store` leg.
   - iPhone/iPad: `IOS_APP_STORE` for `app-store`, `IOS_APP_ADHOC` for `ad-hoc`.
   - The profiles you copied into `PROV_PROF_*` secrets until now are exactly these, so they usually exist already.
2. **The App Store Connect key has the Admin role** and belongs to the team that owns the profiles and certificates. The profile download needs Admin; a weaker key fails the first build step with `App Store Connect answered 403`. An app that lives in another Apple team than LeanBytes (MacPacker, for example) passes that team's key and certificates, as repo secrets. A product with legs in two teams keeps the default key and gives the other team's legs their own ([secrets](#3-secrets)).
3. **Check both before you push.** Run these from your app repo's root, on a Mac with a checkout of this repo:

   ```bash
   # every retired key in your product files, with its replacement
   PRODUCTS_DIR=Config/products python3 ~/path/to/workflows-macos/.github/scripts/products.py discover

   # every profile CI will find: one line per bundle ID
   ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_PATH=~/path/to/AuthKey_XXXX.p8 \
     python3 ~/path/to/workflows-macos/.github/scripts/profiles.py fetch \
       --type MAC_APP_DIRECT --type MAC_APP_STORE --out "$(mktemp -d)"
   ```

   Every bundle ID of every leg you build must show up for its type.
4. **A Tuist app pins Tuist** in a `mise.toml` (or `.mise.toml`, `.tool-versions`) at its root, as above. The build installs exactly that version and stops when there is none.
5. **Self-hosted runner:** one runner process per macOS user. Signing uses that user's keychain search list, so two jobs signing at once under one user break each other.

## From v0.5

### 1. Product file

Each channel becomes a *leg* under `platforms`. The value your app actually used is the product file's key if it has one, else the input in your shell, else the old default (`build-direct` on, everything else off). Shell inputs that set a channel move into the product file too; see [step 2](#2-shells).

| v0.5 key | v0.6.3 |
|---|---|
| `platform` | Delete it. The platform is the key under `platforms`. |
| `build-direct` | `"platforms": {"macos": {"direct": {}}}` |
| `build-app-store` | `"platforms": {"macos": {"app-store": {}}}` |
| `distribute-app-store` | Delete it. An `app-store` leg uploads unless it says `"distribute": false`. |
| `distribute-appcast` | `"appcast": true` on the `direct` leg |
| `scheme-store` | `"scheme"` on the `app-store` leg |
| `bundle-id-store` | `"bundle-id"` on the `app-store` leg |
| `has-finder`, `has-quicklook` | Delete them. Each extension is signed with the profile for its own bundle ID. |
| `bundle-id-finder`, `bundle-id-quicklook`, `bundle-id-finder-store`, `bundle-id-quicklook-store` | Delete them, same reason. |
| `devid-profile-secret`, `store-profile-secret` | Delete them. Profiles come from App Store Connect. |
| `devid-cert-secret`, `devid-cert-password-secret` | `"cert-secret"`, `"cert-password-secret"` on the `direct` leg, plus `"asc-key"` and `"team"` when that certificate is another team's ([secrets](#3-secrets)) |
| `s3-subpath`, `appcast-filename`, `appcast-seed-path`, `changelog-filename` | Move them onto the `direct` leg. |
| `id`, `product-name`, `scheme`, `bundle-id`, `source-paths`, `changelog` | Unchanged |

From workflows-ios: `channel` → `"platforms": {"ios": {"<channel>": {}}}`; `distribute` → onto the leg; `profile-secret` → delete; `cert-secret` / `cert-password-secret` → onto the leg that signs with it.

**Example: a Mac app on Developer ID with Sparkle and on the Mac App Store, with a Finder and a Quick Look extension.**

Before (v0.5), `Config/products/app.json`:

```json
{
  "platform": "macos",
  "product-name": "MyApp",
  "scheme": "MyApp",
  "scheme-store": "MyApp Store",
  "bundle-id": "com.example.myapp",
  "bundle-id-store": "com.example.myapp.mas",
  "has-finder": true,
  "has-quicklook": true,
  "bundle-id-finder": "com.example.myapp.finder",
  "bundle-id-quicklook": "com.example.myapp.quicklook",
  "bundle-id-finder-store": "com.example.myapp.mas.finder",
  "bundle-id-quicklook-store": "com.example.myapp.mas.quicklook",
  "build-direct": true,
  "build-app-store": true,
  "distribute-app-store": true,
  "distribute-appcast": true,
  "s3-subpath": "myapp",
  "appcast-seed-path": "Config/appcast.xml",
  "source-paths": ["MyApp/**", "MyAppFinder/**", "MyAppQuickLook/**", "MyApp.xcodeproj/**"],
  "changelog": { "versions": [ { "version": "2.4.0", "items": [] } ] }
}
```

…with `configuration-app-store: Release Store` in the beta and release shells.

After (v0.6.3):

```json
{
  "product-name": "MyApp",
  "scheme": "MyApp",
  "bundle-id": "com.example.myapp",
  "platforms": {
    "macos": {
      "direct": {
        "appcast": true,
        "s3-subpath": "myapp",
        "appcast-seed-path": "Config/appcast.xml"
      },
      "app-store": {
        "scheme": "MyApp Store",
        "bundle-id": "com.example.myapp.mas",
        "configuration": "Release Store"
      }
    }
  },
  "source-paths": ["MyApp/**", "MyAppFinder/**", "MyAppQuickLook/**", "MyApp.xcodeproj/**"],
  "changelog": { "versions": [ { "version": "2.4.0", "items": [] } ] }
}
```

Nothing names the extensions any more. They still need their profiles in the portal, for both channels: six profiles in this example.

Keep `id` as it was. An empty or missing `id` keeps the bare `vX.Y.Z` and `vX.Y.Z-beta.N` tags counting; a product with an `id` keeps its `<id>-v…` tags.

### 2. Shells

The quickest route is to copy the four templates from [`examples/per-app/`](examples/per-app/) and re-apply your own inputs.

- **`distribute-beta.yml` becomes `distribute.yml`.** Rename your shell file too, and point `uses:` at `distribute.yml@v0.6.3`.
  - Its `workflow_dispatch` input `force-beta` is now `force`.
  - Its `permissions` add `actions: read`: an app without a Direct leg compares against the last successful run.
- **`distribute-pr.yml`, `distribute-release.yml`, `distribute-alpha.yml`, `nightly-tests.yml`, `nightly-memory-watch.yml`** keep their names. Bump their pins to `@v0.6.3`.

Inputs that changed:

| v0.5 input | Shell | v0.6.3 |
|---|---|---|
| `runs-on-build-direct` | beta, release, alpha | `runs-on-build-mac-direct` |
| `runs-on-build-store` | beta | `runs-on-build-mac-store` |
| `runs-on-build-store` | release | Delete it: a release builds only the Direct leg. |
| — | distribute, alpha | `runs-on-build-ios`, new: the iPhone/iPad archive. The alpha shell also gains `runs-on-build-mac-store`. |
| `force-beta` | beta | `force` |
| `build-direct`, `build-app-store` | beta, release | the legs in the product file |
| `distribute-app-store` | beta, release | `"distribute"` on the `app-store` leg (default `true`) |
| `distribute-beta-appcast` | beta | `"appcast": true` on the `direct` leg |
| `distribute-stable-appcast` | release | the same `"appcast": true`. It covers both feeds: betas go to the beta channel, releases to the stable one. |
| `has-finder-extension`, `has-quicklook-extension` | all | Delete them. |
| `appcast-filename`, `appcast-seed-path` | beta, release | onto the `direct` leg |
| `configuration-direct` | beta, release, pr, alpha | `"configuration"` on the `direct` leg |
| `configuration-app-store` | beta, release, pr | `"configuration"` on the `app-store` leg |
| `scheme`, `product-name`, `bundle-id`, `bundle-id-finder`, `bundle-id-quicklook`, `s3-subpath`, `changelog-path` | alpha | Delete them. The alpha reads the product file `product-id` names. |

Unchanged in every shell that has them:

- runners: `runs-on-prepare`, `runs-on-test`, `runs-on-publish`, and on the PR shell `runs-on-discover` and `runs-on-build`
- hooks: `pre-build-cache-path`, `pre-build-cache-key`, `pre-build-script`, `post-build-script`
- build options: `use-tuist`, `lfs`, `extra-xcodebuild-args`, `build-timeout-minutes`, `archive-timeout-minutes`
- artifacts: `artifact-retention-days`, `attach-release-assets`
- `products-dir`, `product-id`, `version-base`
- the test inputs (`run-tests`, `test-scheme`, …). `test-destination` is new and optional.

Example, the distribute shell of the app above. Before:

```yaml
permissions:
  contents: write
jobs:
  beta:
    uses: LeanBytes/workflows-macos/.github/workflows/distribute-beta.yml@v0.5.9
    with:
      force-beta: ${{ inputs.force-beta || false }}
      configuration-app-store: Release Store
      runs-on-build-direct: '"macos-26"'
      runs-on-build-store: '"macos-26"'
      post-build-script: .ci/check-bundle.sh
```

After:

```yaml
permissions:
  contents: write
  actions: read
jobs:
  distribute:
    uses: LeanBytes/workflows-macos/.github/workflows/distribute.yml@v0.6.3
    with:
      force: ${{ inputs.force || false }}
      runs-on-build-mac-direct: '"macos-26"'
      runs-on-build-mac-store: '"macos-26"'
      post-build-script: .ci/check-bundle.sh
```

### 3. Secrets

**Delete from every shell** (and from the repo or org after the first green run):

- `PROV_PROF_DEVID_BASE64`, `PROV_PROF_DEVID_FINDER_BASE64`, `PROV_PROF_DEVID_QL_BASE64`, `PROV_PROF_DEVID_PRO_BASE64`
- `PROV_PROF_STORE_BASE64`, `PROV_PROF_STORE_FINDER_BASE64`, `PROV_PROF_STORE_QL_BASE64`, `PROV_PROF_STORE_PRO_BASE64`

The rest keep their names. What changed per shell:

| Shell | Change |
|---|---|
| `distribute.yml` | The same certificates as the beta shell had. `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_BASE64` now also download the profiles, so the key must be Admin. |
| `distribute-release.yml` | Drop `APPLE_DISTR_*` and `MAC_DISTR_*`: a release rebuilds only the Direct leg. |
| `distribute-alpha.yml` | Add `APPLE_DISTR_P12_BASE64`, `APPLE_DISTR_PASSWORD`, `MAC_DISTR_P12_BASE64`, `MAC_DISTR_PASSWORD` if the product has an `app-store` leg: an alpha builds every leg. |
| `distribute-pr.yml` | Nothing; it signs nothing. |

A leg that signs with another team's certificate (`cert-secret` on the leg) names one of the `*_ALT_*` secrets: `DEVELOPER_ID_P12_ALT_BASE64` / `DEVELOPER_ID_PASSWORD_ALT` or `APPLE_DISTR_P12_ALT_BASE64` / `APPLE_DISTR_PASSWORD_ALT`. Pass it in the shell.

Such a leg needs that team's App Store Connect key as well. The key downloads the profiles, and a key sees only its own team's, so a certificate alone can't sign. Give the leg:

- `"asc-key": "alt"`, and pass `ASC_KEY_ID_ALT`, `ASC_ISSUER_ID_ALT` and `ASC_KEY_ALT_BASE64` (an Admin key of that team) in every shell that builds the leg. It then downloads profiles, notarizes and uploads with that key.
- `"team": "<that team's ID>"`. If the profiles, or a Direct app's signature, come out in any other team, the build fails instead of shipping.

For example, a Direct leg that must stay in an old team, next to an App Store leg in the default team:

```json
"direct": { "cert-secret": "DEVELOPER_ID_P12_ALT_BASE64", "cert-password-secret": "DEVELOPER_ID_PASSWORD_ALT",
            "asc-key": "alt", "team": "OLDTEAM123" },
"app-store": { "scheme": "MyApp_Store", "team": "NEWTEAM456" }
```

### 4. Variables

- `RUNS_ON_BUILD_DIRECT` is now `RUNS_ON_BUILD_MAC_DIRECT`.
- `RUNS_ON_BUILD_STORE` is now `RUNS_ON_BUILD_MAC_STORE`.
- `RUNS_ON_BUILD_IOS` is new.

The old names are no longer read, so rename them or a job moves back to the shell's runner. `S3_DISTRIBUTION_PATH`, `S3_DOWNLOAD_URL` and the `JIRA_*` variables are unchanged.

### 5. What changes in behaviour

- **App Store builds get no tags.** An `app-store` leg uploads to TestFlight with the bare version `X.Y.Z` and a timestamp build number.
  - A product without a Direct leg builds when a push changes its product file or one of its `source-paths` since the last successful run.
  - A product with a Direct leg keeps the Direct beta counter: each `-beta.N` push also uploads a TestFlight build of the same commit.
- **The release tag rebuilds only the Direct leg.** That covers the stable appcast, `Changelog.json` and the GitHub Release. It no longer builds or uploads anything to the App Store. See [From push to App Store review](#from-push-to-app-store-review).
- **An alpha builds every leg of one product.**
  - `app-store` legs upload as internal-only TestFlight builds, which can't go to external testers or to review.
  - Direct and Ad Hoc legs go to an unlisted `alpha/<label>/` S3 prefix.
  - An `-alpha.N` tag is pushed only for a product with a Direct leg.
- **A PR compiles every leg**, unsigned.
- **Public repos keep build artifacts for one day.**
- **The first push after migrating:**
  - A Direct product continues its `-beta.N` count.
  - A product without a Direct leg builds on that push, because the migration commit changes its product file.

### 6. Verify, and how to go back

1. Run `products.py discover` locally (see [Before you start](#before-you-start-every-path)). It must print the legs without an error.
2. Open a PR. `distribute-pr` compiles one job per leg.
3. After merging, open the first `distribute` run:
   - In **Checkout shared scripts**, the log shows the v0.6.3 commit, never `Default branch 'main'`.
   - **Download provisioning profiles** lists every bundle ID of the leg.
4. Delete the `PROV_PROF_*` secrets.

To go back, pin `@v0.5.11` (never v0.5.9 or older) and revert the migration commit.

## From v0.4

v0.4.9 already uses `Config/products/<id>.json` in the v0.5 format. So do the [v0.5 steps](#from-v05), plus these shell changes that v0.5 brought:

- `runs-on-build` is split by archive:
  - distribute shell: `runs-on-build-mac-direct` and `runs-on-build-mac-store`, with the same value for both, plus `runs-on-build-ios` for iPhone/iPad legs.
  - release shell: `runs-on-build-mac-direct`.
  - alpha shell: `runs-on-build-mac-direct`, plus `runs-on-build-mac-store` and `runs-on-build-ios` for those legs.
  - The PR shell keeps `runs-on-build`.
- v0.4 had no `runs-on-prepare`, `runs-on-test` or `runs-on-discover`. They default to `["self-hosted","macOS"]`. On GitHub-hosted runners, set them as well, or the first job waits for a runner forever without failing.
- v0.4's template had no manual trigger. The `force` checkbox comes with the `distribute.yml` template.
- New, all optional: `build-timeout-minutes`, `archive-timeout-minutes`, `post-build-script`, and the `RUNS_ON_*` variables.

## From v0.3

v0.3.50 kept the app's identity in repository variables, the changelog in `Config/Changelog.json`, and the channel switches in the shells. All three move into one product file.

**1. Create `Config/products/app.json`** without an `id`, so the existing `vX.Y.Z` and `vX.Y.Z-beta.N` tags keep counting.

| v0.3 | v0.6.3 |
|---|---|
| Variable `SCHEME_NAME` | `"scheme"` |
| Variable `PRODUCT_NAME` | `"product-name"` |
| Variable `BUNDLE_ID` | `"bundle-id"` |
| Variable `SCHEME_NAME_STORE` | `"scheme"` on the `app-store` leg |
| Variable `BUNDLE_ID_STORE` | `"bundle-id"` on the `app-store` leg |
| Variables `BUNDLE_ID_FINDER`, `BUNDLE_ID_FINDER_STORE`, `BUNDLE_ID_QUICKLOOK`, `BUNDLE_ID_QUICKLOOK_STORE` | Nothing. The extensions need only their profiles. |
| The contents of `Config/Changelog.json` | `"changelog"`, verbatim: same schema |
| Shell inputs `build-direct`, `build-app-store`, `distribute-app-store`, `distribute-beta-appcast`, `configuration-*`, `appcast-*` | The legs, as in the [v0.5 input table](#2-shells) |
| — | `"source-paths"`: list the folders the app builds from. Without them only an edit to the product file counts as a change, and a code-only fix builds nothing. |

If the app bundles `Config/Changelog.json` for its What's New view, read the product file's `changelog` object instead. The schema is the same. On release, CI still publishes it to S3 as `Changelog.json`, and the S3 paths don't change: `S3_DISTRIBUTION_PATH`/`<file>` without an `s3-subpath`.

**2. Shells:** start from the v0.6.3 templates, then follow the [v0.5 shell steps](#2-shells) and the [v0.4 runner notes](#from-v04).
- `changelog-path` is gone.
- The PR shell's `scheme-name` is gone: the scheme comes from the product file.
- **Runners: v0.3 defaulted to GitHub-hosted `macos-26`, v0.6.3 defaults to `["self-hosted","macOS"]`.** To stay on hosted runners, set every `runs-on-*` input to `'"macos-26"'`, prepare and discover included.

**3. Secrets and variables:** as in [v0.5](#3-secrets). After the first green run, delete the identity variables (`SCHEME_NAME`, `SCHEME_NAME_STORE`, `PRODUCT_NAME`, `BUNDLE_ID*`); nothing reads them since v0.4.

## From workflows-ios

The iPhone/iPad workflows moved into this repo, so the shells now call `LeanBytes/workflows-macos`.

**Product file:** `channel` becomes a leg under `platforms.ios`.

| workflows-ios | v0.6.3 |
|---|---|
| `"channel": "app-store"` | `"platforms": {"ios": {"app-store": {}}}` |
| `"channel": "ad-hoc"` | `"platforms": {"ios": {"ad-hoc": {}}}` |
| `"distribute": false` | `"distribute": false` on the leg |
| `profile-secret` | Delete it. |
| `cert-secret`, `cert-password-secret` | onto the leg |

An app on the iPhone and the Mac is one product with both platforms. A Mac leg that needs another scheme says so: `"macos": {"app-store": {"scheme": "MyAppMac"}}`.

**Shells:** copy the v0.6.3 templates.
- `distribute-beta.yml` (v0.2.0) and `distribute.yml` (v0.4.0) both become workflows-macos `distribute.yml`, with `actions: read` in its permissions.
- `distribute-release.yml` is only needed once the product has a Direct leg. Without one, a release tag just marks the version as shipped.

| workflows-ios input | v0.6.3 |
|---|---|
| `distribute` | `"distribute"` on the leg |
| `configuration` | `"configuration"` in the product file |
| `runs-on-build` (distribute) | `runs-on-build-ios` |
| `runs-on-build` (PR) | `runs-on-build`, unchanged |
| `runs-on-prepare` (PR) | `runs-on-discover` |
| `extra-xcodebuild-args` with a signing workaround | Delete the workaround. Every target signs with its own profile now. |

All other inputs keep their names.

**Secrets:**
- Delete `PROV_PROF_STORE_BASE64`, `PROV_PROF_STORE_PRO_BASE64` and any Ad Hoc profile mapped into them.
- **An Ad Hoc app now needs `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_BASE64`** (Admin): it downloads its profile even though it never uploads.

**What stays:**
- The Ad Hoc S3 location is unchanged (`<S3_DISTRIBUTION_PATH>/<bundle-id>/app.ipa` and `manifest.plist`), so existing install links keep working.
- The bare `vX.Y.Z` release markers still stop a version from building.

**What changes:** workflows-ios tagged every build. v0.6.3 writes no such tags and doesn't read the old ones. The first push after migrating builds, because it changes the product file.

## From push to App Store review

1. **Push a change.** `distribute` uploads `X.Y.Z (build)` to TestFlight. With a TestFlight internal group set to automatic distribution, your testers get it right away.
2. **External testers (optional):** in App Store Connect → TestFlight, add the build to an external group. The first build of a version goes through Beta App Review.
3. **Submit:**
   1. In App Store Connect, open the app's version `X.Y.Z` for the platform. Create it if it doesn't exist yet.
   2. Under Build, pick the tested build.
   3. Choose Add for Review, then Submit.
4. **Mark it shipped:** push the tag `vX.Y.Z` (`<id>-vX.Y.Z` for a product with an `id`).
   - From then on that version builds no more. If review rejects it, keep pushing fixes *before* the tag and resubmit a newer build.
   - For a product with a Direct leg, the tag also releases the Direct build to Sparkle users at once. Push it when you want both out.
5. **Start the next version** by adding a new first entry to `changelog.versions`.
