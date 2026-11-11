#!/usr/bin/env bash
# Builds the ticket-pilot menu bar app from this checkout and installs it as
# ~/Applications/TicketPilot.app. Writes only there (plus app/.build in this checkout); needs no elevated rights.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if [ "${1:-}" != "--from-source" ]; then
  echo "Installing from a release is not available yet: it arrives with /ticket-pilot:setup." >&2
  echo "To build and install the app from this checkout, run: ./install.sh --from-source" >&2
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

if [ -z "${HOME:-}" ]; then
  echo "HOME is not set." >&2
  exit 1
fi
destination="$HOME/Applications/TicketPilot.app"
bundle="$HOME/Applications/.TicketPilot.app.new"
trap 'rm -rf "$bundle"' EXIT
mkdir -p "$HOME/Applications"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary" "$bundle/Contents/MacOS/TicketPilot"
sed "s/__VERSION__/$version/g" app/Resources/Info.plist > "$bundle/Contents/Info.plist"
cp app/Resources/AppIcon.icns "$bundle/Contents/Resources/"
codesign --force --sign - "$bundle"

if pgrep -x TicketPilot >/dev/null 2>&1; then
  osascript -e 'quit app "TicketPilot"' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x TicketPilot >/dev/null 2>&1 || break
    sleep 1
  done
fi
if pgrep -x TicketPilot >/dev/null 2>&1; then
  pkill -x TicketPilot || true
  sleep 2
fi
if pgrep -x TicketPilot >/dev/null 2>&1; then
  echo "TicketPilot is still running and could not be stopped. Quit it, then run this script again." >&2
  exit 1
fi

rm -rf "$destination"
mv "$bundle" "$destination"
open "$destination"
echo "Installed $destination (version $version)."
