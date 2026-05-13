#!/usr/bin/env bash
#
# Enrich GitHub auto-generated release notes (Markdown) with Jira ticket
# summaries. For each `* TITLE by @user in URL` line containing a Jira
# key like LB-326, fetch the Jira summary and replace the title text.
# Output line format: `* LB-326: <Jira summary> by @user in URL`.
#
# Inputs (env vars):
#   IN_PATH            Path to Markdown notes file. Required.
#   OUT_PATH           Path to write enriched Markdown. Required (may equal IN_PATH).
#   JIRA_BASE_URL      e.g. https://sarensw.atlassian.net (no trailing slash; we strip).
#   JIRA_USER_EMAIL    Atlassian account email that owns the API token.
#   JIRA_API_TOKEN     API token. If empty/unset, copies IN_PATH to OUT_PATH
#                      unchanged and exits 0 (graceful for fork PRs / non-Jira apps).
#   JIRA_KEY_PREFIX    Default "LB". Configures which key namespace to recognize
#                      (e.g. "MP" for macpacker if you ever split projects).
#
# Behavior:
#   * Replace only the title text in each bullet line; preserve the bullet
#     marker and the "by @author in <URL>" tail.
#   * Original line preserved on any Jira fetch failure (4xx / 5xx /
#     network / timeout). Build NEVER fails because of this script.
#   * Missing token = pass-through (works for apps without Jira).

set -euo pipefail

: "${IN_PATH:?IN_PATH is required}"
: "${OUT_PATH:?OUT_PATH is required}"

if [ ! -f "$IN_PATH" ]; then
  echo "::error::IN_PATH does not exist: $IN_PATH" >&2
  exit 1
fi

JIRA_API_TOKEN="${JIRA_API_TOKEN:-}"
JIRA_KEY_PREFIX="${JIRA_KEY_PREFIX:-LB}"

if [ -z "$JIRA_API_TOKEN" ]; then
  echo "::warning::JIRA_API_TOKEN is empty; skipping Jira enrichment (passthrough)"
  cp "$IN_PATH" "$OUT_PATH"
  exit 0
fi

: "${JIRA_BASE_URL:?JIRA_BASE_URL is required when JIRA_API_TOKEN is set}"
: "${JIRA_USER_EMAIL:?JIRA_USER_EMAIL is required when JIRA_API_TOKEN is set}"

JIRA_BASE_URL="${JIRA_BASE_URL%/}"

export IN_PATH OUT_PATH JIRA_BASE_URL JIRA_USER_EMAIL JIRA_API_TOKEN JIRA_KEY_PREFIX

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
PREFIX = os.environ["JIRA_KEY_PREFIX"]

TIMEOUT_S = 5
RETRY_DELAY_S = 0.5

KEY_RE = re.compile(rf"\b{re.escape(PREFIX)}-(\d+)\b")
# Match "* TITLE by @USER in URL" or "- TITLE ..."; capture bullet, title, tail.
LINE_RE = re.compile(r"^(\s*[\*\-]\s+)(.*?)(\s+by\s+@\S+\s+in\s+\S+)?\s*$")

auth = base64.b64encode(f"{EMAIL}:{TOKEN}".encode("utf-8")).decode("ascii")
HEADERS = {
    "Authorization": f"Basic {auth}",
    "Accept": "application/json",
    "User-Agent": "LeanBytes-changelog-enricher/1.0",
}


def log_warning(msg):
    print(f"::warning::{msg}", file=sys.stderr)


def log_error(msg):
    print(f"::error::{msg}", file=sys.stderr)


def fetch_summary(key, attempt=1):
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


with open(IN_PATH, encoding="utf-8") as fh:
    input_text = fh.read()

lines_out = []
enriched = 0
fallback = 0
no_key = 0

for line in input_text.splitlines():
    m_line = LINE_RE.match(line)
    if not m_line:
        lines_out.append(line)
        continue
    bullet, title, tail = m_line.group(1), m_line.group(2), m_line.group(3) or ""
    m_key = KEY_RE.search(title)
    if not m_key:
        no_key += 1
        lines_out.append(line)
        continue
    key = f"{PREFIX}-{m_key.group(1)}"
    try:
        summary = fetch_summary(key)
    except urllib.error.HTTPError as e:
        if e.code == 401:
            log_error(f"Jira 401 for {key} — token may be expired. Keeping original.")
        elif e.code == 404:
            log_warning(f"Jira ticket {key} not found (404). Keeping original.")
        else:
            log_warning(f"Jira HTTP {e.code} for {key}. Keeping original.")
        fallback += 1
        lines_out.append(line)
        continue
    except Exception as e:
        log_warning(f"Jira fetch failed for {key}: {e}. Keeping original.")
        fallback += 1
        lines_out.append(line)
        continue

    enriched += 1
    lines_out.append(f"{bullet}{key}: {summary}{tail}")

with open(OUT_PATH, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines_out))
    if input_text.endswith("\n"):
        fh.write("\n")

print(
    f"Enriched {enriched} lines from Jira; "
    f"{fallback} fell back to original; "
    f"{no_key} had no {PREFIX}-NNN key.",
    file=sys.stderr,
)
PY
