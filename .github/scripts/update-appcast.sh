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

if [ -z "$NOTES_VAR" ]; then
  echo "::warning::NOTES is empty; skipping description injection (only trim will run)"
else
  echo "Injecting release notes into appcast item for version $VERSION (length: ${#NOTES_VAR})"
  export APPCAST_PATH VERSION
  NOTES="$NOTES_VAR" python3 <<'PY'
import os
import sys
import xml.etree.ElementTree as ET

path = os.environ["APPCAST_PATH"]
ver = os.environ["VERSION"]
notes = os.environ["NOTES"]

ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
ET.register_namespace("sparkle", ns["sparkle"])

tree = ET.parse(path)
root = tree.getroot()
channel = root.find("channel")
if channel is None:
    print("::warning::appcast has no <channel>", file=sys.stderr)
    sys.exit(0)

# Match by sparkle:version (build number, unique per build) OR
# sparkle:shortVersionString (marketing version). Stable releases pass
# the marketing version; beta builds pass the build number since their
# marketing version repeats across PR merges.
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
    sys.exit(0)

for old in target.findall("description"):
    target.remove(old)

desc = ET.SubElement(target, "description")
desc.text = "@@CDATA_OPEN@@" + notes + "@@CDATA_CLOSE@@"

tree.write(path, xml_declaration=True, encoding="utf-8")

with open(path, "r", encoding="utf-8") as fh:
    xml = fh.read()
xml = xml.replace("@@CDATA_OPEN@@", "<![CDATA[").replace("@@CDATA_CLOSE@@", "]]>")
with open(path, "w", encoding="utf-8") as fh:
    fh.write(xml)
print(f"Injected release notes for version {ver}")
PY
fi

# Trim the appcast to the most recent APPCAST_MAX_ITEMS items.
echo "Trimming appcast to $APPCAST_MAX_ITEMS items"
APPCAST_MAX_ITEMS="$APPCAST_MAX_ITEMS" APPCAST_PATH="$APPCAST_PATH" python3 <<'PY'
import os
import xml.etree.ElementTree as ET

path = os.environ["APPCAST_PATH"]
limit = int(os.environ["APPCAST_MAX_ITEMS"])

ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
ET.register_namespace("sparkle", ns["sparkle"])
tree = ET.parse(path)
root = tree.getroot()
channel = root.find("channel")
if channel is None:
    print("::warning::no <channel> to trim")
else:
    items = channel.findall("item")
    if len(items) > limit:
        for stale in items[limit:]:
            channel.remove(stale)
        print(f"Trimmed appcast from {len(items)} to {limit} items")
    else:
        print(f"Appcast has {len(items)} items, no trim needed")
tree.write(path, xml_declaration=True, encoding="utf-8")
PY

echo "update-appcast.sh complete"
