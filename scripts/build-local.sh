#!/usr/bin/env bash
#
# Local Developer ID Direct build — run the SAME pipeline CI runs, on your Mac,
# with no commit/push and no CI minutes. This is a thin wrapper around the shared
# core `.github/scripts/build-direct.sh` (the exact script `_build-direct.yml`
# runs); it sources a local env file holding the same secrets + vars CI uses,
# computes a local version, and runs every phase in one process.
#
# One-time setup:
#   1. Copy examples/local-build.env.example to a file OUTSIDE any git repo
#      (it holds a base64 signing cert), e.g. ~/.config/workflows-macos/<app>.env.
#      Fill it from your app repo's GitHub secrets + vars, then `chmod 600` it.
#   2. Ensure any pre-build asset is present (or set PRE_BUILD_SCRIPT in the env).
#
# Run from your app repo (or pass --project-dir):
#   build-local.sh --env-file ~/.config/workflows-macos/flowmoose.env
#   build-local.sh --env-file … --skip-notarize --no-dmg   # fast signing-only loop
#
# Output: <project>/dist/<PRODUCT_NAME>_<version>.{zip,dmg}
# The notarization round-trip (~1-3 min) dominates; --skip-notarize --no-dmg
# is the fast inner loop while iterating on signing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="$(cd "$SCRIPT_DIR/.." && pwd)/.github/scripts/build-direct.sh"

PROJECT_DIR="$PWD"
ENV_FILE=""
CLI_VERSION=""
CLI_OUTPUT_DIR=""
CLI_SCHEME=""
CLI_BUNDLE_ID=""
CLI_PRODUCT_NAME=""
CLI_CONFIGURATION=""

usage() {
  cat >&2 <<'USAGE'
build-local.sh — local Developer ID Direct build (same pipeline as CI)

Usage:
  build-local.sh [options]

Options:
  --env-file PATH      env file to source (default: <project>/Config/local-build.env)
  --project-dir DIR    app repo working copy (default: current directory)
  --version VER        marketing version (default: <Changelog versions[0]>-local.<build>)
  --output-dir DIR     where the .zip/.dmg land (default: <project>/dist)
  --scheme NAME        override SCHEME_NAME from the env file
  --bundle-id ID       override BUNDLE_ID
  --product-name NAME  override PRODUCT_NAME
  --configuration C    override CONFIGURATION (default: Release)
  --skip-notarize      sign + package only — NOT Gatekeeper-valid on other Macs
  --no-dmg             ZIP only, skip the DMG (faster)
  --keep               keep the intermediate build dir
  -h, --help           show this help

The env file holds the SAME base64 secrets + vars CI uses — store it outside any
git repo and chmod 600 it. See examples/local-build.env.example.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file)      ENV_FILE="$2"; shift 2 ;;
    --project-dir)   PROJECT_DIR="$2"; shift 2 ;;
    --version)       CLI_VERSION="$2"; shift 2 ;;
    --output-dir)    CLI_OUTPUT_DIR="$2"; shift 2 ;;
    --scheme)        CLI_SCHEME="$2"; shift 2 ;;
    --bundle-id)     CLI_BUNDLE_ID="$2"; shift 2 ;;
    --product-name)  CLI_PRODUCT_NAME="$2"; shift 2 ;;
    --configuration) CLI_CONFIGURATION="$2"; shift 2 ;;
    --skip-notarize) export SKIP_NOTARIZE=1; shift ;;
    --no-dmg)        export NO_DMG=1; shift ;;
    --keep)          export KEEP=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

[ -f "$CORE" ] || { echo "error: shared core not found at $CORE" >&2; exit 1; }
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

# Resolve the env file: explicit flag, else the in-repo default.
if [ -z "$ENV_FILE" ]; then
  ENV_FILE="$PROJECT_DIR/Config/local-build.env"
fi
if [ ! -f "$ENV_FILE" ]; then
  echo "error: env file not found: $ENV_FILE" >&2
  echo "       copy examples/local-build.env.example, fill it, and pass --env-file." >&2
  exit 1
fi

# set -a → every assignment in the env file is exported, so the core (a child
# process) inherits SCHEME_NAME, the base64 secrets, USE_TUIST, etc.
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

# CLI overrides win over the env file.
if [ -n "$CLI_SCHEME" ];        then export SCHEME_NAME="$CLI_SCHEME"; fi
if [ -n "$CLI_BUNDLE_ID" ];     then export BUNDLE_ID="$CLI_BUNDLE_ID"; fi
if [ -n "$CLI_PRODUCT_NAME" ];  then export PRODUCT_NAME="$CLI_PRODUCT_NAME"; fi
if [ -n "$CLI_CONFIGURATION" ]; then export CONFIGURATION="$CLI_CONFIGURATION"; fi

BUILD_NUMBER="$(date -u +%y%m%d%H%M%S)"

if [ -n "$CLI_VERSION" ]; then
  VERSION="$CLI_VERSION"
else
  CL="$PROJECT_DIR/Config/Changelog.json"
  if [ ! -f "$CL" ]; then
    echo "error: $CL not found; pass --version explicitly" >&2
    exit 1
  fi
  BASE="$(CHANGELOG_PATH="$CL" python3 -c 'import json, os, sys
d = json.load(open(os.environ["CHANGELOG_PATH"]))
v = d.get("versions") or []
if not v or "version" not in v[0]: sys.exit("Changelog.json has no versions[0].version")
print(v[0]["version"])')"
  VERSION="${BASE}-local.${BUILD_NUMBER}"
fi

# Local artifacts mirror CI's <PRODUCT_NAME>_<label>.{zip,dmg}; the local version
# (with its -local. marker) is the natural label.
ARTIFACT_LABEL="$VERSION"

if [ -n "$CLI_OUTPUT_DIR" ]; then
  OUTPUT_DIR="$CLI_OUTPUT_DIR"
else
  OUTPUT_DIR="$PROJECT_DIR/dist"
fi
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

WORK_DIR="$(mktemp -d)"

export VERSION BUILD_NUMBER ARTIFACT_LABEL OUTPUT_DIR WORK_DIR

echo "Local Direct build"
echo "  Project:  $PROJECT_DIR"
echo "  Env file: $ENV_FILE"
echo "  Version:  $VERSION   Build: $BUILD_NUMBER"
echo "  Output:   $OUTPUT_DIR"
if [ -n "${SKIP_NOTARIZE:-}" ]; then echo "  Mode:     skip-notarize (NOT Gatekeeper-valid on other Macs)"; fi
if [ -n "${NO_DMG:-}" ]; then echo "  Mode:     no-dmg (ZIP only)"; fi

# Run the build from the app repo so xcodebuild/tuist and any PRE_BUILD_SCRIPT
# resolve relative to it — same as CI's checkout.
cd "$PROJECT_DIR"
exec bash "$CORE" all
