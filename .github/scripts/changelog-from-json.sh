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
#   PRODUCT           Optional per-product filter (e.g. "base", "pro").
#                     When set, items carrying a non-empty `products`
#                     array that does not list PRODUCT are dropped; items
#                     with no `products` apply to every product. Unset
#                     (single-product callers) → no filtering.
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

CHANGELOG_PATH="$CHANGELOG_PATH" VERSION="$VERSION" PRODUCT="${PRODUCT:-}" python3 <<'PY'
import json
import os
import sys

path = os.environ["CHANGELOG_PATH"]
version = os.environ["VERSION"]
product = os.environ.get("PRODUCT", "").strip()

with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

# Accept a per-product product.json directly (v0.4.0): descend into its inline
# .changelog. A plain Changelog.json has top-level "versions"; a product.json
# nests the same schema under "changelog".
if "versions" not in data and isinstance(data.get("changelog"), dict):
    data = data["changelog"]

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
    # Optional per-product filter: when PRODUCT is set, drop items whose
    # `products` array is present, non-empty, and does not list PRODUCT.
    # An absent/empty `products` means "applies to every product". When
    # PRODUCT is unset (single-product callers), no filtering happens.
    prods = item.get("products")
    if product and isinstance(prods, list) and prods and product not in prods:
        continue
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
