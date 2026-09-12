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
#     ### Localization    (type: lang)
#     ### Announcements   (type: release)
# Empty sections are omitted. These five are exactly the types the apps' own
# "What's New" views render, so the two stay aligned — they drifted before, and
# six MacPacker releases shipped without their `lang` items (#17).
#
# `chore` is dropped on purpose: it is internal work and MUST NOT leak into the
# customer-facing notes. Any OTHER type is also dropped — a stray internal note
# must not reach customers on the strength of a typo — but loudly, via a
# ::warning:: and a $GITHUB_STEP_SUMMARY line, because stdout here IS the
# release notes (callers redirect it to a file) and a silent drop is how this
# went unnoticed for six releases.
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
    ("Localization", ("lang",)),
    ("Announcements", ("release",)),
]
# Dropped on purpose, without a warning: chore was replaced by core, and legacy
# entries still carry it. Anything outside SECTIONS *and* this set is a typo or
# a type the apps grew without telling CI — dropped too, but reported.
SILENT_DROP = ("chore",)


def warn(msg):
    """Report to the step log and the run page. NEVER stdout — that is the notes."""
    print(f"::warning::{msg}", file=sys.stderr)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write(f"> [!WARNING]\n> {msg}\n\n")

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
    else:
        if type_ not in SILENT_DROP:
            warn(
                f"{path}: unknown changelog type {type_ or '(empty)'!r} on "
                f"version {target.get('version', '<unknown>')} — dropped from the "
                f"release notes and the appcast: {title!r}. Known types: "
                f"{', '.join(t for _, a in SECTIONS for t in a)}."
            )

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
