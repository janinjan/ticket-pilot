#!/usr/bin/env bash
# Builds the ticket-pilot menu bar app from this checkout into the bundle given as argument
# (for example dist/TicketPilot.app), replacing it, and signs it. Writes only there and in app/.build.
#
# Signing: with TICKET_PILOT_SIGN_IDENTITY set to a code signing identity, the app is signed with it, the
# hardened runtime and a secure timestamp (what notarization needs); otherwise it is signed ad hoc.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

bundle="${1:-}"
if [ -z "$bundle" ]; then
  echo "Usage: ./build-app.sh <path/to/TicketPilot.app>" >&2
  exit 2
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "swift was not found. Install Xcode (from the App Store), open it once, then run this script again." >&2
  exit 1
fi

version=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' .claude-plugin/plugin.json)
if [ -z "$version" ]; then
  echo "Could not read the version from .claude-plugin/plugin.json." >&2
  exit 1
fi

swift build -c release --package-path app --arch arm64 --arch x86_64
# The folder depends on the Swift version, so ask SwiftPM instead of hard-coding it.
binary="$(swift build -c release --package-path app --arch arm64 --arch x86_64 --show-bin-path)/TicketPilot"
if [ ! -x "$binary" ]; then
  echo "The build did not produce $binary" >&2
  exit 1
fi

rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary" "$bundle/Contents/MacOS/TicketPilot"
sed "s/__VERSION__/$version/g" app/Resources/Info.plist > "$bundle/Contents/Info.plist"
cp app/Resources/AppIcon.icns "$bundle/Contents/Resources/"
# The Claude Code plugin the app installs or updates: only what the plugin needs (never app/, tests/ or
# the repository's own folders), signed with the bundle.
plugin="$bundle/Contents/Resources/plugin"
mkdir -p "$plugin"
cp -R .claude-plugin skills agents hooks bin ticket_pilot "$plugin/"
cp LICENSE README.md config.example.json "$plugin/"
find "$plugin" \( -name __pycache__ -o -name '*.pyc' -o -name .DS_Store \) -prune -exec rm -rf {} +

if [ -n "${TICKET_PILOT_SIGN_IDENTITY:-}" ]; then
  # A signing identity keeps the app the same for the Keychain from one build to the next, so its
  # "Always Allow" lasts. The hardened runtime blocks Apple Events unless entitled: the app drives the
  # terminal with osascript.
  codesign --force --options runtime --timestamp \
    --entitlements app/Resources/TicketPilot.entitlements \
    --sign "$TICKET_PILOT_SIGN_IDENTITY" "$bundle"
else
  # Ad hoc: macOS asks again to read the Keychain after each install.
  codesign --force --sign - "$bundle"
fi
echo "Built $bundle (version $version)."
