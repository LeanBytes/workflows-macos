#!/usr/bin/env bash
#
# Derive the marketing version (CFBundleShortVersionString) for a CI build.
#
# LB-402: the git tag is the source of truth for release versions, and
# `git describe --tags` derives a uniquely-identified version for each
# pre-release build. Config/Version.xcconfig only holds a frozen
# placeholder (0.0.0-dev) for local Xcode debug builds and is overridden
# by `xcodebuild MARKETING_VERSION=...` in distribute-build.yml.
#
# Usage:
#   version-derive.sh release <tag-ref>     -> "1.0.2"
#   version-derive.sh snapshot              -> "1.0.2-3-gabcdef"
#   version-derive.sh pr                    -> "1.0.2-3-gabcdef"
#
# `release` accepts either a bare tag ("v1.0.2") or a fully-qualified
# ref ("refs/tags/v1.0.2") so callers can pass `${GITHUB_REF}` or
# `${GITHUB_REF_NAME}` without massaging it first.
#
# Exit codes:
#   0  success — version on stdout
#   1  bad input or no tag found
#
# Diagnostics go to stderr; only the version string goes to stdout so
# `VERSION=$(version-derive.sh ...)` works.

set -euo pipefail

usage() {
  echo "Usage: $0 <release <tag-ref> | snapshot | pr>" >&2
  exit 1
}

[ $# -lt 1 ] && usage

MODE="$1"

# Strip a leading "v" from a version-like string. Accepts both "v1.2.3"
# and "1.2.3"; returns the input unchanged if there is no "v" prefix.
strip_v() {
  local s="$1"
  echo "${s#v}"
}

case "$MODE" in
  release)
    [ $# -lt 2 ] && {
      echo "::error::release mode requires a tag ref" >&2
      usage
    }
    REF="$2"
    # Accept refs/tags/v1.2.3 by stripping the prefix; bare v1.2.3 passes through.
    TAG="${REF#refs/tags/}"
    VERSION=$(strip_v "$TAG")

    if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "::error::ref '${REF}' does not parse to a valid semver (got '${VERSION}'). Release builds require a tag like v1.2.3." >&2
      exit 1
    fi

    echo "$VERSION"
    ;;

  snapshot|pr)
    # Walk back to the latest stable tag, ignoring beta-suffixed tags
    # (same exclude pattern as generate-changelog.sh). --long forces the
    # "-N-gSHA" suffix even when HEAD is exactly on a tag, so callers
    # always see "1.0.2-0-gabcdef" rather than ambiguously "1.0.2".
    if ! DESCRIBED=$(git describe --tags --long --match='v*.*.*' --exclude='*-beta-*' 2>/dev/null); then
      echo "::error::git describe --tags failed. Did the checkout fetch tags? (set fetch-depth: 0 on actions/checkout)" >&2
      exit 1
    fi

    if [ -z "$DESCRIBED" ]; then
      echo "::error::git describe returned empty. No matching v*.*.* tag in history." >&2
      exit 1
    fi

    VERSION=$(strip_v "$DESCRIBED")
    echo "$VERSION"
    ;;

  *)
    echo "::error::unknown mode '$MODE'" >&2
    usage
    ;;
esac
