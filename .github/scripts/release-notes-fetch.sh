#!/usr/bin/env bash
#
# Fetch GitHub auto-generated release notes for the diff between two refs,
# WITHOUT creating a GitHub Release object. Returns the Markdown body on
# stdout — orchestrators capture it, optionally pipe through Jira enrichment,
# then inject into appcast.xml + ASC "What's New" + the eventual `gh release
# create` call.
#
# Inputs (env vars):
#   PREVIOUS_TAG        Tag to compare against (e.g. v1.2.2). Required.
#   TARGET              The new tag or commit SHA to compare to (e.g. v1.2.3
#                       for a release, or "main" for a beta). Required.
#   GITHUB_REPOSITORY   Standard GH Actions env var (owner/repo). Required.
#   GH_TOKEN            Token with repo:read access. Defaults to
#                       GITHUB_TOKEN if set; required either way.
#
# Usage:
#   notes=$(PREVIOUS_TAG=v1.2.2 TARGET=v1.2.3 release-notes-fetch.sh)
#
# Why this script vs `gh release create --generate-notes`: the latter creates
# the Release object as a side effect. We want the notes BEFORE the build
# runs, so we can inject into appcast/TestFlight, and only create the Release
# object after every other publish step succeeds.

set -euo pipefail

: "${PREVIOUS_TAG:?PREVIOUS_TAG is required}"
: "${TARGET:?TARGET is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required (owner/repo)}"

# gh reads GH_TOKEN or GITHUB_TOKEN. Surface explicit GH_TOKEN if set,
# otherwise let gh fall back to GITHUB_TOKEN from the runner env.
if [ -n "${GH_TOKEN:-}" ]; then
  export GH_TOKEN
elif [ -n "${GITHUB_TOKEN:-}" ]; then
  export GH_TOKEN="$GITHUB_TOKEN"
else
  echo "::error::GH_TOKEN or GITHUB_TOKEN is required" >&2
  exit 1
fi

# POST /repos/{owner}/{repo}/releases/generate-notes
# https://docs.github.com/en/rest/releases/releases#generate-release-notes-content-for-a-release
gh api \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  "/repos/${GITHUB_REPOSITORY}/releases/generate-notes" \
  -f tag_name="${TARGET}" \
  -f previous_tag_name="${PREVIOUS_TAG}" \
  --jq '.body'
