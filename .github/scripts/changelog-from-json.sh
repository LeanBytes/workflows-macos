#!/usr/bin/env bash
#
# Render customer-facing release notes Markdown from a caller-owned
# Changelog.json. The same file is loaded by the app's "What's New" view,
# so the appcast description and the in-product changelog stay aligned.
#
# Inputs (env vars):
#   CHANGELOG_PATH    Path to Changelog.json. Required.
#   VERSION           Either an exact marketing version (e.g. "2.11.0")
#                     to match `versions[].version`, OR the literal
#                     sentinel "NEXT" to use `versions[0]` (the
#                     in-progress entry the developer is curating).
#                     Required.
#
# Output: Markdown on stdout. Bucketed into:
#     ### New Features    (type: feat)
#     ### Bug Fixes       (type: fix)
#     ### Improvements    (type: core)
# Empty sections are omitted. `chore` and any other unrecognized type are
# silently skipped — they MUST NOT leak into the customer-facing notes.
#
# If the version isn't found (or the JSON has no `versions`), emit a
# ::warning:: and exit 0 with empty stdout. update-appcast.sh tolerates
# empty NOTES and just skips the description injection.

set -euo pipefail

: "${CHANGELOG_PATH:?CHANGELOG_PATH is required}"
: "${VERSION:?VERSION is required (exact marketing version, or the NEXT sentinel)}"

if [ ! -f "$CHANGELOG_PATH" ]; then
  echo "::error::CHANGELOG_PATH does not exist: $CHANGELOG_PATH" >&2
  exit 1
fi

CHANGELOG_PATH="$CHANGELOG_PATH" VERSION="$VERSION" python3 <<'PY'
import json
import os
import sys

path = os.environ["CHANGELOG_PATH"]
version = os.environ["VERSION"]

with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

versions = data.get("versions") or []

if version == "NEXT":
    if not versions:
        print(f"::warning::{path} has no versions[]; nothing to render", file=sys.stderr)
        sys.exit(0)
    target = versions[0]
    matched_version = target.get("version", "<unknown>")
    print(f"Using versions[0] (NEXT sentinel) → version={matched_version}", file=sys.stderr)
else:
    target = None
    for entry in versions:
        if entry.get("version") == version:
            target = entry
            break
    if target is None:
        print(f"::warning::No entry in {path} matching version={version}", file=sys.stderr)
        sys.exit(0)

# (section_title, accepted_type_values). Order here drives output order.
SECTIONS = [
    ("New Features", ("feat",)),
    ("Bug Fixes", ("fix",)),
    ("Improvements", ("core",)),
]
# chore is intentionally NOT mapped — it was replaced by core. Any chore
# items in legacy entries (and any unrecognized type) are dropped.

buckets = {label: [] for label, _ in SECTIONS}
for item in target.get("items") or []:
    title = ((item.get("title") or {}).get("en") or "").strip()
    if not title:
        continue
    type_ = (item.get("type") or "").strip().lower()
    for label, accepted in SECTIONS:
        if type_ in accepted:
            buckets[label].append(title)
            break
    # No "else" — unmatched types are skipped.

rendered = []
for label, _ in SECTIONS:
    titles = buckets[label]
    if not titles:
        continue
    body = "\n".join(f"* {t}" for t in titles)
    rendered.append(f"### {label}\n{body}")

if rendered:
    print("\n\n".join(rendered))
PY
