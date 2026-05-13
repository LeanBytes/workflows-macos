#!/usr/bin/env bash
#
# Generate / update CHANGELOG.json for the current build by walking
# squash-merge commit titles since the previous version on this channel.
#
# Inputs (env vars):
#   IN_PATH       Path to existing CHANGELOG.json (download from S3 first;
#                 fall back to repo's Config/CHANGELOG.json seed).
#   OUT_PATH      Path to write the updated CHANGELOG.json.
#   VERSION       Marketing version (e.g., "1.0.1") for stable, or build
#                 identifier for beta — whatever uniquely identifies the
#                 release on its channel.
#   BUILD_NUMBER  Build number (timestamp).
#   CHANNEL       "stable" or "beta".
#
# Optional:
#   PRODUCT_NAME            Default "FlowMoose".
#   RELEASED_AT             ISO 8601 timestamp; default = now.
#   CHANGELOG_MAX_VERSIONS  Cap on stored versions (default 50, oldest dropped).
#   PR_TITLE                Beta only: when set together with PR_NUMBER,
#                           the script emits one entry built directly from
#                           them and skips the HEAD~1..HEAD git-log walk.
#                           This is the path used by distribute-snapshot.yml
#                           on `pull_request: closed`, where actions/checkout
#                           lands on a synthetic merge commit whose
#                           HEAD~1..HEAD doesn't match the (#NN) filter.
#   PR_NUMBER               Beta only: PR number for the PR_TITLE entry.
#
# Behavior:
#   * If versions[0] already matches {version, channel} of this build,
#     the script preserves its entries and only refreshes generated_at.
#     This is the seam for the first stable release: the user
#     hand-curates v1.0.0 entries in Config/CHANGELOG.json before
#     tagging, and this idempotency keeps those entries intact.
#   * For stable: walks `git log $LAST_TAG..HEAD` where $LAST_TAG matches
#     v*.*.* and is NOT a beta tag. If no such tag exists, entries is [].
#   * For beta with PR_TITLE+PR_NUMBER set: emits one entry from them
#     (the post-LB-397 happy path; the title is later replaced by Jira
#     summary via enrich-changelog-with-jira.sh).
#   * For beta without PR_TITLE+PR_NUMBER: walks `git log HEAD~1..HEAD`
#     (legacy / workflow_dispatch path; produces empty entries on the
#     synthetic merge commit checked out for pull_request events).
#   * Only commits with a "(#NUM)" PR-number suffix are included in the
#     git-log walk; direct pushes to main are skipped per LB-326 decision.
#   * New version entry is prepended to `versions` (newest first).
#   * Trims to CHANGELOG_MAX_VERSIONS (oldest dropped).

set -euo pipefail

: "${IN_PATH:?IN_PATH is required}"
: "${OUT_PATH:?OUT_PATH is required}"
: "${VERSION:?VERSION is required}"
: "${BUILD_NUMBER:?BUILD_NUMBER is required}"
: "${CHANNEL:?CHANNEL is required (stable|beta)}"

export PRODUCT_NAME="${PRODUCT_NAME:-FlowMoose}"
export RELEASED_AT="${RELEASED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
export CHANGELOG_MAX_VERSIONS="${CHANGELOG_MAX_VERSIONS:-50}"

# Determine commit range
RANGE=""
if [ "$CHANNEL" = "beta" ]; then
  if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
    RANGE="HEAD~1..HEAD"
  fi
elif [ "$CHANNEL" = "stable" ]; then
  if LAST_TAG=$(git describe --tags --abbrev=0 --match='v*.*.*' --exclude='*-beta-*' 2>/dev/null); then
    RANGE="${LAST_TAG}..HEAD"
  fi
else
  echo "::error::CHANNEL must be 'stable' or 'beta', got '$CHANNEL'" >&2
  exit 1
fi

if [ -n "$RANGE" ]; then
  GIT_LOG_OUTPUT=$(git log --pretty=format:'%H%x09%s%x09%aI' "$RANGE" 2>/dev/null || echo "")
else
  GIT_LOG_OUTPUT=""
fi
export GIT_LOG_OUTPUT

PR_TITLE="${PR_TITLE:-}"
PR_NUMBER="${PR_NUMBER:-}"
export PR_TITLE PR_NUMBER
export VERSION BUILD_NUMBER CHANNEL IN_PATH OUT_PATH

python3 <<'PY'
import json
import os
import re
import subprocess
import sys

product = os.environ["PRODUCT_NAME"]
version = os.environ["VERSION"]
build = os.environ["BUILD_NUMBER"]
channel = os.environ["CHANNEL"]
released_at = os.environ["RELEASED_AT"]
in_path = os.environ["IN_PATH"]
out_path = os.environ["OUT_PATH"]
max_versions = int(os.environ["CHANGELOG_MAX_VERSIONS"])
git_log_output = os.environ.get("GIT_LOG_OUTPUT", "")
pr_title = os.environ.get("PR_TITLE", "").strip()
pr_number_raw = os.environ.get("PR_NUMBER", "").strip()

if os.path.exists(in_path):
    with open(in_path) as fh:
        data = json.load(fh)
else:
    print(f"No existing changelog at {in_path}; starting fresh.")
    data = {"product": product, "generated_at": "", "versions": []}

data.setdefault("product", product)
data["generated_at"] = released_at
versions = data.setdefault("versions", [])

# Idempotency: scan the full versions array (not just the top) so CI
# re-runs don't duplicate entries.
#
# For stable: match on {version, channel}. The user pre-populates the
# seed for v1.0.0 with the hand-curated 5-point summary and no `build`
# field (the timestamp isn't known when writing the seed). CI runs at
# tag time with a build number, finds v1.0.0 already present, no-ops.
# Each marketing version is tagged at most once, so version+channel is
# the unique key.
#
# For beta: marketing version repeats across PR merges, so the build
# number is the unique distinguisher. Match on {version, build, channel}.
def matches(v):
    if v.get("version") != version or v.get("channel") != channel:
        return False
    if channel == "beta":
        return v.get("build") == build
    return True

already_present = any(matches(v) for v in versions)
if already_present:
    if channel == "beta":
        print(f"Version {version} build {build} ({channel}) already in changelog; not adding duplicate.")
    else:
        print(f"Version {version} ({channel}) already in changelog; preserving its entries.")
else:
    entries = []

    # LB-397: when distribute-snapshot.yml fires on `pull_request: closed`,
    # actions/checkout lands on a synthetic merge commit whose
    # HEAD~1..HEAD doesn't carry the (#NN) suffix that the git-log filter
    # below requires. The workflow exports the real PR title/number as
    # env vars and we build a single entry directly from them, skipping
    # the broken git-log walk for the beta-on-PR path.
    use_pr_event_path = (
        channel == "beta"
        and pr_title
        and pr_number_raw
    )

    if use_pr_event_path:
        try:
            pr_number = int(pr_number_raw)
        except ValueError:
            print(f"::warning::PR_NUMBER='{pr_number_raw}' is not an integer; falling back to git-log walk.")
            use_pr_event_path = False

    if use_pr_event_path:
        # Best-effort sha and merged_at — for pull_request events HEAD is
        # the synthetic merge, not the squash-merge on main. The fields
        # are metadata for tooling, not customer-facing.
        try:
            sha = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], text=True
            ).strip()[:8]
        except Exception:
            sha = ""
        try:
            merged_at = subprocess.check_output(
                ["git", "log", "-1", "--format=%aI"], text=True
            ).strip()
        except Exception:
            merged_at = released_at

        title_clean = re.sub(r"\s*\(#\d+\)\s*$", "", pr_title).strip()
        entries.append({
            "title": title_clean,
            "pr": pr_number,
            "sha": sha,
            "merged_at": merged_at,
        })
    else:
        for line in git_log_output.splitlines():
            if not line.strip():
                continue
            parts = line.split("\t")
            if len(parts) < 3:
                continue
            sha, title, dt = parts
            match = re.search(r"\(#(\d+)\)\s*$", title)
            if not match:
                # Skip direct commits without a PR number per LB-326 decision.
                continue
            pr = int(match.group(1))
            title_clean = re.sub(r"\s*\(#\d+\)\s*$", "", title).strip()
            entries.append({
                "title": title_clean,
                "pr": pr,
                "sha": sha[:8],
                "merged_at": dt,
            })

    new_entry = {
        "version": version,
        "build": build,
        "channel": channel,
        "released_at": released_at,
        "entries": entries,
    }
    versions.insert(0, new_entry)
    print(f"Added new version entry: {version} ({channel}) with {len(entries)} PR entries.")

if len(versions) > max_versions:
    dropped = len(versions) - max_versions
    versions[:] = versions[:max_versions]
    print(f"Trimmed {dropped} oldest versions (cap = {max_versions}).")

data["versions"] = versions

with open(out_path, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")

print(f"Wrote CHANGELOG.json to {out_path}")
PY
