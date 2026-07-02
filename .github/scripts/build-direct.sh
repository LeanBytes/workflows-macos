#!/usr/bin/env bash
#
# Build, sign, notarize, staple, and package a macOS app for Developer ID
# Direct distribution (the Sparkle channel). Output: a notarized + stapled
# .app, packaged as a DMG and a ZIP, in OUTPUT_DIR.
#
# SINGLE SOURCE OF TRUTH for the Direct build. Two callers:
#   • CI — `_build-direct.yml` checks this repo out into `.shared-ci/` (at the
#     same commit, via github.job_workflow_sha) and runs ONE phase per named
#     workflow step, so the GitHub Actions UI keeps its per-step names,
#     timings, and pass/fail icons:
#         bash .shared-ci/.github/scripts/build-direct.sh archive
#   • Local — `scripts/build-local.sh` sources a local env file (the SAME
#     base64 secrets + vars CI uses) and runs every phase in one process:
#         bash .github/scripts/build-direct.sh all
#
# Because CI runs each phase as a SEPARATE process, no phase may rely on
# in-memory state from a previous one. Paths are pure functions of the env.
# Profile Names are captured during `signing` (BEFORE archive — `xcodebuild`
# renames the files under ~/Library/MobileDevice/Provisioning Profiles/ to
# UUIDs) and persisted to WORK_DIR for `export` to read; the installed profile
# is still matched by Name at export time. Everything else is re-derived.
#
# Usage:
#   build-direct.sh <phase>     # run a single phase (CI: one per workflow step)
#   build-direct.sh all         # run setup→…→verify-packages, trap cleanup (local)
#
# Phases:
#   setup            resolve SwiftPM deps, or `tuist install && generate`
#   signing          ephemeral keychain + provisioning profiles + ASC key
#   archive          xcodebuild archive
#   export           xcodebuild -exportArchive (method=developer-id, manual)
#   notarize         notarytool submit --wait (+ fetch log on rejection)
#   staple           stapler staple
#   verify           pre-package: stapler validate + spctl + codesign
#   package          DMG (hdiutil) + ZIP (ditto, metadata-stripped)
#   verify-packages  post-package: re-check spctl + codesign from DMG & ZIP
#   cleanup          delete keychain/profiles/ASC key, restore search list
#
# Required env (config):
#   SCHEME_NAME BUNDLE_ID PRODUCT_NAME VERSION BUILD_NUMBER ARTIFACT_LABEL
#   WORK_DIR    intermediates (xcarchive, export); deleted by cleanup
#   OUTPUT_DIR  where the .dmg/.zip land; NEVER deleted by cleanup
# Required env (secrets; base64 unless noted):
#   DEVELOPER_ID_P12_BASE64  DEVELOPER_ID_PASSWORD (plain)  KEYCHAIN_PASSWORD (plain)
#   PROV_PROF_DEVID_BASE64
#   ASC_KEY_ID (plain)  ASC_ISSUER_ID (plain)  ASC_KEY_BASE64
# Optional env:
#   USE_TUIST=true|false (default false)   CONFIGURATION (default Release)
#   EXTRA_ARGS (extra xcodebuild settings; word-split intentionally — unquoted)
#   PRE_BUILD_SCRIPT (bash script run in `setup`; CI also runs it as a native step)
#   HAS_FINDER / HAS_QUICKLOOK = true|false (+ BUNDLE_ID_FINDER / BUNDLE_ID_QUICKLOOK
#     and PROV_PROF_DEVID_FINDER_BASE64 / PROV_PROF_DEVID_QL_BASE64)
#   SKIP_NOTARIZE / NO_DMG / KEEP  (non-empty = on; local fast-iteration knobs.
#     CI leaves these unset → full run.)
#
# MUST stay in lockstep with `_build-direct.yml`'s step list. Load-bearing
# details that must NOT drift: the `ditto … --norsrc --noextattr --noacl`
# packaging flags (without them, __MACOSX/._* companion files break the embedded
# Sparkle.framework signature → Gatekeeper rejection); MARKETING_VERSION /
# CURRENT_PROJECT_VERSION at archive time; method=developer-id; and the
# spctl + `codesign --deep --strict` + `stapler validate` verification set.

set -euo pipefail

# ── Defaults for optional knobs ──────────────────────────────────────────────
USE_TUIST="${USE_TUIST:-false}"
CONFIGURATION="${CONFIGURATION:-Release}"
EXTRA_ARGS="${EXTRA_ARGS:-}"
HAS_FINDER="${HAS_FINDER:-false}"
HAS_QUICKLOOK="${HAS_QUICKLOOK:-false}"

banner() {
  echo ""
  echo "═══ $* ═══"
}

# Path model — a pure function of the env, called by every phase so each phase
# (separate process under CI) reconstructs the same paths without shared state.
compute_paths() {
  : "${WORK_DIR:?WORK_DIR is required}"
  : "${OUTPUT_DIR:?OUTPUT_DIR is required}"
  : "${PRODUCT_NAME:?PRODUCT_NAME is required}"
  : "${ARTIFACT_LABEL:?ARTIFACT_LABEL is required}"

  ARCHIVE="$WORK_DIR/app.xcarchive"
  EXPORT_DIR="$WORK_DIR/export"
  APP="$EXPORT_DIR/${PRODUCT_NAME}.app"
  DMG_PATH="$OUTPUT_DIR/${PRODUCT_NAME}_${ARTIFACT_LABEL}.dmg"
  ZIP_PATH="$OUTPUT_DIR/${PRODUCT_NAME}_${ARTIFACT_LABEL}.zip"
  PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"

  mkdir -p "$WORK_DIR"
}

# Human-readable Name from a CMS-wrapped .provisionprofile — same extraction as
# CI. Errors loudly (rather than returning empty) when the file isn't a valid
# profile, which almost always means a bad/empty/placeholder base64 secret.
profile_name() {
  local n
  n="$(security cms -D -i "$1" 2>/dev/null | plutil -extract Name raw - 2>/dev/null)" || true
  if [ -z "$n" ]; then
    echo "::error::Could not read a profile Name from '$1' — is the matching PROV_PROF_*_BASE64 a valid, complete base64 of a .provisionprofile?" >&2
    return 1
  fi
  printf '%s\n' "$n"
}

# Read a profile Name that `signing` captured (pre-archive) into WORK_DIR. Used
# by `export` instead of re-reading the profile file, which xcodebuild may have
# renamed during archive.
read_profile_name() {
  local f="$WORK_DIR/.profile-name-$1"
  if [ ! -s "$f" ]; then
    echo "::error::No saved profile name for '$1' ($f). Did the 'signing' phase run before 'export'?" >&2
    return 1
  fi
  cat "$f"
}

# Restore the keychain search list snapshotted during `signing`. No snapshot ⇒
# `signing` never modified the list (e.g. a build that failed earlier) ⇒ leave
# the list untouched, so we never clobber a dev's custom keychains. Tolerates
# paths with spaces.
restore_keychains() {
  local snap="$WORK_DIR/.orig-keychains"
  [ -f "$snap" ] || return 0
  local kc=() line
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"   # ltrim
    line="${line%\"}"; line="${line#\"}"        # strip surrounding quotes
    if [ -n "$line" ]; then kc+=("$line"); fi
  done < "$snap"
  if [ "${#kc[@]}" -gt 0 ]; then
    security list-keychains -d user -s "${kc[@]}"
  fi
}

# ── Phases ───────────────────────────────────────────────────────────────────
phase_setup() {
  banner "Resolve dependencies"
  if [ "$USE_TUIST" = "true" ]; then
    # Tuist via mise. The Homebrew tap (`brew tap tuist/tuist`) is broken upstream
    # — its cask carries an invalid `conflicts_with formula:` stanza that fails the
    # tap outright — so Tuist is installed through mise instead. mise is installed
    # with its official one-liner (the same method used on the self-hosted runner);
    # it lands in ~/.local/bin, which isn't on PATH by default, so we prepend it.
    # A committed mise.toml / .tool-versions pin is honored (reproducible builds);
    # without one we fall back to latest. Runners that already have mise skip the
    # install; CI auto-trusts the repo config (CI=true), so no `mise trust`.
    # `mise exec` runs Tuist without needing it on PATH (mise shims aren't active
    # in the non-interactive CI shell).
    export PATH="$HOME/.local/bin:$PATH"
    command -v mise >/dev/null 2>&1 || curl https://mise.run | sh
    mise install
    mise exec -- tuist --version >/dev/null 2>&1 || mise use tuist@latest
    mise exec -- tuist install
    mise exec -- tuist generate --no-open
  else
    : "${SCHEME_NAME:?SCHEME_NAME is required}"
    xcodebuild -resolvePackageDependencies \
      -scheme "$SCHEME_NAME" \
      -configuration Release
  fi
  # Optional caller asset hook (e.g. download a model). CI runs this as its own
  # native step; locally it runs here when PRE_BUILD_SCRIPT is set.
  if [ -n "${PRE_BUILD_SCRIPT:-}" ]; then
    echo "Running pre-build script: $PRE_BUILD_SCRIPT"
    bash "$PRE_BUILD_SCRIPT"
  fi
}

phase_signing() {
  banner "Set up signing"
  : "${DEVELOPER_ID_P12_BASE64:?}"; : "${DEVELOPER_ID_PASSWORD:?}"; : "${KEYCHAIN_PASSWORD:?}"
  : "${PROV_PROF_DEVID_BASE64:?}"
  : "${ASC_KEY_ID:?}"; : "${ASC_KEY_BASE64:?}"

  # Snapshot the search list BEFORE touching it, so cleanup restores the machine
  # exactly (on CI that's just login.keychain; a dev Mac may have more).
  security list-keychains -d user > "$WORK_DIR/.orig-keychains"

  # Ephemeral keychain from the base64 Developer ID p12.
  echo "$DEVELOPER_ID_P12_BASE64" | base64 --decode > "$WORK_DIR/certificate.p12"
  security delete-keychain build.keychain 2>/dev/null || true
  security create-keychain -p "$KEYCHAIN_PASSWORD" build.keychain
  security import "$WORK_DIR/certificate.p12" \
    -k build.keychain \
    -P "$DEVELOPER_ID_PASSWORD" \
    -T /usr/bin/codesign
  security set-key-partition-list \
    -S apple-tool:,apple: \
    -s -k "$KEYCHAIN_PASSWORD" \
    build.keychain
  security list-keychains -d user -s build.keychain login.keychain
  rm -f "$WORK_DIR/certificate.p12"

  # Provisioning profiles. Capture each profile's Name HERE (before archive) and
  # persist it to WORK_DIR — `xcodebuild archive` renames the files under the
  # Provisioning Profiles dir, so the pp-*.provisionprofile path may be gone by
  # export time. The assignment (not an echo-inline) lets a failed, empty
  # profile_name abort here with a clear message rather than later.
  mkdir -p "$PROFILE_DIR"
  local prof
  echo "$PROV_PROF_DEVID_BASE64" | base64 --decode > "$PROFILE_DIR/pp-devid.provisionprofile"
  prof="$(profile_name "$PROFILE_DIR/pp-devid.provisionprofile")"
  printf '%s\n' "$prof" > "$WORK_DIR/.profile-name-main"
  echo "Main profile: $prof"

  if [ "$HAS_FINDER" = "true" ]; then
    : "${PROV_PROF_DEVID_FINDER_BASE64:?has-finder-extension set but PROV_PROF_DEVID_FINDER_BASE64 missing}"
    echo "$PROV_PROF_DEVID_FINDER_BASE64" | base64 --decode > "$PROFILE_DIR/pp-devid-finder.provisionprofile"
    prof="$(profile_name "$PROFILE_DIR/pp-devid-finder.provisionprofile")"
    printf '%s\n' "$prof" > "$WORK_DIR/.profile-name-finder"
    echo "Finder profile: $prof"
  fi
  if [ "$HAS_QUICKLOOK" = "true" ]; then
    : "${PROV_PROF_DEVID_QL_BASE64:?has-quicklook-extension set but PROV_PROF_DEVID_QL_BASE64 missing}"
    echo "$PROV_PROF_DEVID_QL_BASE64" | base64 --decode > "$PROFILE_DIR/pp-devid-quicklook.provisionprofile"
    prof="$(profile_name "$PROFILE_DIR/pp-devid-quicklook.provisionprofile")"
    printf '%s\n' "$prof" > "$WORK_DIR/.profile-name-quicklook"
    echo "Quick Look profile: $prof"
  fi

  # App Store Connect API key for notarytool.
  mkdir -p "$HOME/.appstoreconnect/private_keys"
  echo "$ASC_KEY_BASE64" | base64 --decode \
    > "$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"

  security find-identity -v -p codesigning build.keychain
}

phase_archive() {
  banner "Archive"
  : "${SCHEME_NAME:?}"; : "${VERSION:?}"; : "${BUILD_NUMBER:?}"
  rm -rf "$ARCHIVE"
  # EXTRA_ARGS is intentionally UNQUOTED so it word-splits into separate
  # xcodebuild build-setting args (e.g. BUILD_RELEASE_DATE=...). Do not quote.
  xcodebuild archive \
    -scheme "$SCHEME_NAME" \
    -configuration "$CONFIGURATION" \
    -archivePath "$ARCHIVE" \
    -destination "generic/platform=macOS" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    $EXTRA_ARGS
}

phase_export() {
  banner "Export"
  : "${BUNDLE_ID:?}"

  # Names captured by `signing` before archive (the profile files may have been
  # renamed by xcodebuild since); the installed profiles are still matched by Name.
  local profiles_xml
  profiles_xml="<key>${BUNDLE_ID}</key><string>$(read_profile_name main)</string>"
  if [ "$HAS_FINDER" = "true" ]; then
    : "${BUNDLE_ID_FINDER:?}"
    profiles_xml="${profiles_xml}<key>${BUNDLE_ID_FINDER}</key><string>$(read_profile_name finder)</string>"
  fi
  if [ "$HAS_QUICKLOOK" = "true" ]; then
    : "${BUNDLE_ID_QUICKLOOK:?}"
    profiles_xml="${profiles_xml}<key>${BUNDLE_ID_QUICKLOOK}</key><string>$(read_profile_name quicklook)</string>"
  fi

  # Unquoted PLIST delimiter so ${profiles_xml} expands. Closing delimiter must
  # stay at column 0.
  cat > "$WORK_DIR/ExportOptions.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>provisioningProfiles</key>
  <dict>
    ${profiles_xml}
  </dict>
</dict>
</plist>
PLIST

  # Surfaced so a bundle-id ↔ profile mismatch is obvious in the log (not secret —
  # just bundle ids + profile names).
  echo "Exporting with BUNDLE_ID='${BUNDLE_ID}' and ExportOptions.plist:"
  cat "$WORK_DIR/ExportOptions.plist"

  rm -rf "$EXPORT_DIR"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$WORK_DIR/ExportOptions.plist"
}

phase_notarize() {
  banner "Notarize"
  : "${ASC_KEY_ID:?}"; : "${ASC_ISSUER_ID:?}"
  local key="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"

  ditto -c -k --keepParent "$APP" "$WORK_DIR/notarize.zip"

  # `|| true` so a non-zero notarytool exit still lets us parse the status and
  # fetch the rejection log below, instead of dying silently at the assignment.
  local submit_output submission_id status
  submit_output=$(xcrun notarytool submit "$WORK_DIR/notarize.zip" \
    --key "$key" \
    --key-id "$ASC_KEY_ID" \
    --issuer "$ASC_ISSUER_ID" \
    --wait 2>&1) || true
  echo "$submit_output"

  submission_id=$(echo "$submit_output" | grep '^\s*id:' | head -1 | sed 's/.*id: //') || true
  status=$(echo "$submit_output" | grep '^\s*status:' | tail -1 | sed 's/.*status: //') || true

  if [[ "$status" != "Accepted" ]]; then
    echo "::error::Notarization failed with status: ${status:-<none>} — fetching rejection log"
    xcrun notarytool log "$submission_id" \
      --key "$key" \
      --key-id "$ASC_KEY_ID" \
      --issuer "$ASC_ISSUER_ID" || true
    exit 1
  fi
  rm -f "$WORK_DIR/notarize.zip"
}

phase_staple() {
  banner "Staple"
  xcrun stapler staple "$APP"
}

phase_verify() {
  banner "Verify (pre-package)"
  if [ -n "${SKIP_NOTARIZE:-}" ]; then
    echo "SKIP_NOTARIZE set — signature check only (no staple / Gatekeeper assessment)."
    codesign --verify --deep --strict --verbose=4 "$APP"
  else
    xcrun stapler validate -v "$APP"
    spctl --assess --type execute --verbose=4 "$APP"
    codesign --verify --deep --strict --verbose=4 "$APP"
  fi
}

phase_package() {
  banner "Create DMG and ZIP"
  mkdir -p "$OUTPUT_DIR"

  if [ -z "${NO_DMG:-}" ]; then
    rm -rf "$WORK_DIR/dmg"
    mkdir -p "$WORK_DIR/dmg"
    cp -R "$APP" "$WORK_DIR/dmg/"
    ln -s /Applications "$WORK_DIR/dmg/Applications"
    hdiutil create \
      -volname "$PRODUCT_NAME" \
      -srcfolder "$WORK_DIR/dmg" \
      -ov \
      -format UDZO \
      "$DMG_PATH"
    rm -rf "$WORK_DIR/dmg"
    echo "DMG: $DMG_PATH"
  else
    echo "NO_DMG set — skipping DMG."
  fi

  # --norsrc --noextattr --noacl strip macOS-only metadata so the ZIP has no
  # __MACOSX/._* entries. Without them, Archive Utility materializes ._* files
  # inside Sparkle.framework/ and breaks its signature ("unsealed contents in
  # the root directory of an embedded framework") → Gatekeeper rejection.
  ditto -c -k --keepParent --norsrc --noextattr --noacl "$APP" "$ZIP_PATH"
  echo "ZIP: $ZIP_PATH"
}

phase_verify_packages() {
  banner "Verify packaged"
  local app_name="${PRODUCT_NAME}.app"

  if [ -z "${NO_DMG:-}" ]; then
    local mount rc=0
    mount=$(hdiutil attach -nobrowse -readonly "$DMG_PATH" | awk 'END{print $NF}')
    spctl --assess --type execute --verbose=4 "$mount/$app_name" || rc=$?
    codesign --verify --deep --strict --verbose=4 "$mount/$app_name" || rc=$?
    hdiutil detach "$mount" || true        # detach even if a check failed
    [ "$rc" -eq 0 ] || { echo "::error::DMG verification failed"; exit 1; }
  fi

  local tmp
  tmp=$(mktemp -d)
  ditto -x -k "$ZIP_PATH" "$tmp"
  spctl --assess --type execute --verbose=4 "$tmp/$app_name"
  codesign --verify --deep --strict --verbose=4 "$tmp/$app_name"
  rm -rf "$tmp"
}

phase_cleanup() {
  banner "Cleanup"
  security delete-keychain build.keychain 2>/dev/null || true
  rm -f "$PROFILE_DIR/pp-devid.provisionprofile"
  rm -f "$PROFILE_DIR/pp-devid-finder.provisionprofile"
  rm -f "$PROFILE_DIR/pp-devid-quicklook.provisionprofile"
  if [ -n "${ASC_KEY_ID:-}" ]; then
    rm -f "$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
  fi
  restore_keychains
  [ -n "${KEEP:-}" ] || rm -rf "$WORK_DIR"
}

print_summary() {
  echo ""
  echo "── Direct build complete ──"
  echo "  Version: ${VERSION:-?}   Build: ${BUILD_NUMBER:-?}"
  if [ -f "$ZIP_PATH" ]; then echo "  ZIP:     $ZIP_PATH"; fi
  if [ -f "$DMG_PATH" ]; then echo "  DMG:     $DMG_PATH"; fi
}

usage() {
  cat >&2 <<'USAGE'
build-direct.sh — Developer ID Direct build (sign, notarize, staple, package)

Usage:
  build-direct.sh <phase>    Run a single phase (CI runs one per workflow step)
  build-direct.sh all        Run every phase in order (local); traps cleanup

Phases: setup signing archive export notarize staple verify package
        verify-packages cleanup

Driven entirely by environment variables — see the header of this file, or
scripts/build-local.sh for the local wrapper. CI sets them in _build-direct.yml.
USAGE
}

# ── Dispatch ─────────────────────────────────────────────────────────────────
PHASE="${1:-all}"
case "$PHASE" in -h|--help|help) usage; exit 0 ;; esac

compute_paths

case "$PHASE" in
  setup)            phase_setup ;;
  signing)          phase_signing ;;
  archive)          phase_archive ;;
  export)           phase_export ;;
  notarize)         phase_notarize ;;
  staple)           phase_staple ;;
  verify)           phase_verify ;;
  package)          phase_package ;;
  verify-packages)  phase_verify_packages ;;
  cleanup)          phase_cleanup ;;
  all)
    trap phase_cleanup EXIT
    phase_setup
    phase_signing
    phase_archive
    phase_export
    if [ -z "${SKIP_NOTARIZE:-}" ]; then
      phase_notarize
      phase_staple
    else
      echo "Skipping notarize + staple (SKIP_NOTARIZE)."
    fi
    phase_verify
    phase_package
    if [ -z "${SKIP_NOTARIZE:-}" ]; then
      phase_verify_packages
    else
      echo "Skipping post-package verification (SKIP_NOTARIZE)."
    fi
    print_summary
    ;;
  *)
    echo "::error::Unknown phase: $PHASE" >&2
    echo "Run '$0 --help' for the phase list." >&2
    exit 1
    ;;
esac
