#!/usr/bin/env bash
# Writes the manifest.plist an itms-services:// link points at.
#
# iOS fetches this plist first and the IPA from it; both MUST be served over
# HTTPS with a valid certificate, or the install fails without a useful message.
# display-image/full-size-image are optional and left out on purpose: without
# them iOS shows its placeholder, and a dead image link would be worse.
#
# Usage: manifest.sh <ipa-url> <bundle-id> <bundle-version> <title>
set -euo pipefail

IPA_URL="$1"
BUNDLE_ID="$2"
BUNDLE_VERSION="$3"
TITLE="$4"

cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>items</key>
  <array>
    <dict>
      <key>assets</key>
      <array>
        <dict>
          <key>kind</key>
          <string>software-package</string>
          <key>url</key>
          <string>${IPA_URL}</string>
        </dict>
      </array>
      <key>metadata</key>
      <dict>
        <key>bundle-identifier</key>
        <string>${BUNDLE_ID}</string>
        <key>bundle-version</key>
        <string>${BUNDLE_VERSION}</string>
        <key>kind</key>
        <string>software</string>
        <key>title</key>
        <string>${TITLE}</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
PLIST
