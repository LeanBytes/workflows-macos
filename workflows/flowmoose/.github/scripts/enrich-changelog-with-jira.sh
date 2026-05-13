#!/usr/bin/env bash
#
# Enrich CHANGELOG.json entries with Jira ticket summaries.
#
# Reads versions[0].entries[]. For each entry:
#   * If entries[].jira_key is already set, prefer it.
#   * Else extract the first \bLB-(\d+)\b match from entries[].title.
#   * If a key is found, GET {JIRA_BASE_URL}/rest/api/3/issue/{key}?fields=summary
#     with HTTP Basic auth, replace .title with response.fields.summary,
#     and set .jira_key + .jira_url.
#   * On any failure (4xx / 5xx / network / timeout), keep the original
#     title and emit ::warning:: (or ::error:: for 401).
#
# Inputs (env vars):
#   IN_PATH           Path to existing CHANGELOG.json.
#   OUT_PATH          Path to write the enriched CHANGELOG.json (may equal IN_PATH).
#   JIRA_BASE_URL     e.g. https://sarensw.atlassian.net (no trailing slash; we strip one if present).
#   JIRA_USER_EMAIL   Atlassian account email that owns the API token.
#   JIRA_API_TOKEN    API token. If empty/unset, the script copies IN_PATH
#                     to OUT_PATH unchanged and exits 0 (graceful for fork PRs).
#
# Behavior:
#   * Only versions[0] (the just-built release) is touched. Historical
#     entries are immutable.
#   * Idempotent: re-running on already-enriched entries refreshes the
#     summary from Jira (handles the "ticket title was edited" case),
#     because we prefer .jira_key over title-regex when both are set.
#   * The build NEVER fails because of this script. Worst case = .title
#     stays as the PR/commit title and the Actions log shows ::warning::
#     or ::error::.

set -euo pipefail

: "${IN_PATH:?IN_PATH is required}"
: "${OUT_PATH:?OUT_PATH is required}"

if [ ! -f "$IN_PATH" ]; then
  echo "::error::IN_PATH does not exist: $IN_PATH" >&2
  exit 1
fi

JIRA_API_TOKEN="${JIRA_API_TOKEN:-}"
if [ -z "$JIRA_API_TOKEN" ]; then
  echo "::warning::JIRA_API_TOKEN is empty; skipping Jira enrichment (entries keep their original titles)"
  cp "$IN_PATH" "$OUT_PATH"
  exit 0
fi

: "${JIRA_BASE_URL:?JIRA_BASE_URL is required when JIRA_API_TOKEN is set}"
: "${JIRA_USER_EMAIL:?JIRA_USER_EMAIL is required when JIRA_API_TOKEN is set}"

# Strip trailing slash from base URL so {BASE_URL}/rest/... has exactly one slash.
JIRA_BASE_URL="${JIRA_BASE_URL%/}"

export IN_PATH OUT_PATH JIRA_BASE_URL JIRA_USER_EMAIL JIRA_API_TOKEN

python3 <<'PY'
import base64
import json
import os
import re
import socket
import sys
import time
import urllib.error
import urllib.request

IN_PATH = os.environ["IN_PATH"]
OUT_PATH = os.environ["OUT_PATH"]
BASE_URL = os.environ["JIRA_BASE_URL"]
EMAIL = os.environ["JIRA_USER_EMAIL"]
TOKEN = os.environ["JIRA_API_TOKEN"]

TIMEOUT_S = 5
RETRY_DELAY_S = 0.5
JIRA_KEY_RE = re.compile(r"\bLB-(\d+)\b")

auth = base64.b64encode(f"{EMAIL}:{TOKEN}".encode("utf-8")).decode("ascii")
HEADERS = {
    "Authorization": f"Basic {auth}",
    "Accept": "application/json",
    "User-Agent": "FlowMoose-changelog-enricher/1.0",
}


def log_warning(msg):
    print(f"::warning::{msg}", file=sys.stderr)


def log_error(msg):
    print(f"::error::{msg}", file=sys.stderr)


def fetch_summary(key, attempt=1):
    """Return the Jira ticket summary for `key`, or raise."""
    url = f"{BASE_URL}/rest/api/3/issue/{key}?fields=summary"
    req = urllib.request.Request(url, headers=HEADERS)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_S) as resp:
            data = json.load(resp)
    except urllib.error.HTTPError as e:
        if e.code in (500, 502, 503, 504) and attempt == 1:
            time.sleep(RETRY_DELAY_S)
            return fetch_summary(key, attempt=2)
        raise
    except (urllib.error.URLError, socket.timeout, TimeoutError, OSError):
        if attempt == 1:
            time.sleep(RETRY_DELAY_S)
            return fetch_summary(key, attempt=2)
        raise

    summary = data.get("fields", {}).get("summary")
    if not summary:
        raise RuntimeError(f"Jira response for {key} missing fields.summary")
    return summary


def extract_key(entry):
    """Return the LB-NNN key for this entry, or None."""
    explicit = entry.get("jira_key")
    if explicit and JIRA_KEY_RE.fullmatch(explicit):
        return explicit
    title = entry.get("title") or ""
    m = JIRA_KEY_RE.search(title)
    if m:
        return f"LB-{m.group(1)}"
    return None


with open(IN_PATH) as fh:
    data = json.load(fh)

versions = data.get("versions") or []
if not versions:
    print("No versions in CHANGELOG.json; nothing to enrich.")
    with open(OUT_PATH, "w") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
    sys.exit(0)

target = versions[0]
entries = target.get("entries") or []
if not entries:
    print("versions[0].entries is empty; nothing to enrich.")
    with open(OUT_PATH, "w") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
    sys.exit(0)

enriched = 0
fallback = 0
no_key = 0

for entry in entries:
    key = extract_key(entry)
    if not key:
        # No LB-NNN — leave the entry alone. Per workflow rules every PR
        # should have a key, but rule violations don't fail the build.
        no_key += 1
        continue
    try:
        summary = fetch_summary(key)
    except urllib.error.HTTPError as e:
        if e.code == 401:
            log_error(
                f"Jira 401 unauthorized for {key} — token may be expired or "
                f"lacks permission. Keeping original title."
            )
        elif e.code == 404:
            log_warning(f"Jira ticket {key} not found (404). Keeping original title.")
        else:
            log_warning(f"Jira returned HTTP {e.code} for {key}. Keeping original title.")
        fallback += 1
        continue
    except Exception as e:
        log_warning(f"Jira fetch failed for {key}: {e}. Keeping original title.")
        fallback += 1
        continue

    entry["title"] = summary
    entry["jira_key"] = key
    entry["jira_url"] = f"{BASE_URL}/browse/{key}"
    enriched += 1

print(
    f"Enriched {enriched} entries from Jira; "
    f"{fallback} fell back to original title; "
    f"{no_key} had no LB-NNN key."
)

with open(OUT_PATH, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
