#!/usr/bin/env bash
#
# Inject release notes into the latest appcast item and trim the appcast
# to the most recent N items so the file doesn't grow unbounded.
#
# Inputs (env vars):
#   APPCAST_PATH      Path to the appcast.xml that `generate_appcast` produced.
#   VERSION           sparkle:version (build number, beta) OR
#                     sparkle:shortVersionString (marketing, stable) of the
#                     item to receive the description.
#   NOTES             Release notes content (Markdown). May be empty —
#                     in which case no description is injected and only
#                     the trim runs.
#
# Optional:
#   APPCAST_MAX_ITEMS  Default 20.

set -euo pipefail

: "${APPCAST_PATH:?APPCAST_PATH is required}"
: "${VERSION:?VERSION is required}"
APPCAST_MAX_ITEMS="${APPCAST_MAX_ITEMS:-20}"

if [ ! -f "$APPCAST_PATH" ]; then
  echo "::error::APPCAST_PATH does not exist: $APPCAST_PATH" >&2
  exit 1
fi

NOTES_VAR="${NOTES:-}"
PLACEHOLDER="@@APPCAST_NOTES_PLACEHOLDER@@"

if [ -z "$NOTES_VAR" ]; then
  echo "::warning::NOTES is empty; skipping description injection (only trim will run)"
fi

# Single ElementTree pass: trim first, then (if notes present) drop a plain-text
# placeholder for the description body. The CDATA substitution happens AFTER
# ET is done — see the second python block. Doing both in one ET cycle avoids
# the trim destroying the CDATA wrapper and double-escaping `&` to `&amp;amp;`.
APPCAST_PATH="$APPCAST_PATH" \
VERSION="$VERSION" \
APPCAST_MAX_ITEMS="$APPCAST_MAX_ITEMS" \
HAS_NOTES="$([ -n "$NOTES_VAR" ] && echo 1 || echo 0)" \
PLACEHOLDER="$PLACEHOLDER" \
python3 <<'PY'
import os
import sys
import xml.etree.ElementTree as ET

path = os.environ["APPCAST_PATH"]
ver = os.environ["VERSION"]
limit = int(os.environ["APPCAST_MAX_ITEMS"])
has_notes = os.environ["HAS_NOTES"] == "1"
placeholder = os.environ["PLACEHOLDER"]

ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
ET.register_namespace("sparkle", ns["sparkle"])

tree = ET.parse(path)
root = tree.getroot()
channel = root.find("channel")
if channel is None:
    print("::warning::appcast has no <channel>", file=sys.stderr)
    sys.exit(0)

items = channel.findall("item")
if len(items) > limit:
    for stale in items[limit:]:
        channel.remove(stale)
    print(f"Trimmed appcast from {len(items)} to {limit} items")
else:
    print(f"Appcast has {len(items)} items, no trim needed")

if has_notes:
    target = None
    for item in channel.findall("item"):
        sv = item.find("sparkle:version", ns)
        svs = item.find("sparkle:shortVersionString", ns)
        if sv is not None and sv.text and sv.text.strip() == ver:
            target = item
            break
        if svs is not None and svs.text and svs.text.strip() == ver:
            target = item
            break

    if target is None:
        print(f"::warning::No <item> found matching version={ver}", file=sys.stderr)
    else:
        for old in target.findall("description"):
            target.remove(old)
        desc = ET.SubElement(target, "description")
        # Tell Sparkle the CDATA is Markdown so its update window renders it
        # formatted (Sparkle late 2025, sparkle-project/Sparkle#2810). Older
        # Sparkle ignores the attribute and treats the body as HTML.
        desc.set("{http://www.andymatuschak.org/xml-namespaces/sparkle}format", "markdown")
        # Single placeholder that the post-write text substitution turns into a
        # CDATA block. Keeping the body out of ET means `&` / `<` / `>` in the
        # notes go into the CDATA verbatim, not as `&amp;` / `&lt;` / `&gt;`.
        desc.text = placeholder
        print(f"Injected release notes placeholder for version {ver}")

tree.write(path, xml_declaration=True, encoding="utf-8")
PY

# Post-write substitution: turn the placeholder into a real CDATA block carrying
# the raw notes. Defend against ]]> inside the notes by splitting the CDATA
# section there (the standard "]]]]><![CDATA[>" escape).
if [ -n "$NOTES_VAR" ]; then
  PLACEHOLDER="$PLACEHOLDER" APPCAST_PATH="$APPCAST_PATH" NOTES="$NOTES_VAR" python3 <<'PY'
import os

path = os.environ["APPCAST_PATH"]
placeholder = os.environ["PLACEHOLDER"]
notes = os.environ["NOTES"]

safe_notes = notes.replace("]]>", "]]]]><![CDATA[>")
cdata = "<![CDATA[" + safe_notes + "]]>"

with open(path, "r", encoding="utf-8") as fh:
    xml = fh.read()

if placeholder not in xml:
    print(f"::warning::placeholder not found in {path}; CDATA not substituted")
else:
    xml = xml.replace(placeholder, cdata, 1)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(xml)
    print("CDATA-wrapped release notes substituted into appcast")
PY
fi

echo "update-appcast.sh complete"
