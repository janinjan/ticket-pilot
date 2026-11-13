#!/usr/bin/env bash
# Builds the ticket-pilot menu bar app from this checkout (with build-app.sh) and installs it as
# /Applications/TicketPilot.app. Writes only there (plus app/.build in this checkout) and removes an old
# ~/Applications/TicketPilot.app; needs no elevated rights.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if [ "${1:-}" != "--from-source" ]; then
  echo "To install a release, download TicketPilot-<version>.zip from https://github.com/janinjan/ticket-pilot/releases," >&2
  echo "unzip it and move TicketPilot.app to /Applications." >&2
  echo "To build and install the app from this checkout, run: ./install.sh --from-source" >&2
  exit 2
fi

if [ -z "${HOME:-}" ]; then
  echo "HOME is not set." >&2
  exit 1
fi
destination="/Applications/TicketPilot.app"
bundle="/Applications/.TicketPilot.app.new"
if [ ! -w /Applications ]; then
  echo "/Applications is not writable by this user. Make it writable and run this script again, or drag the app into /Applications by hand (build it with ./build-app.sh dist/TicketPilot.app)." >&2
  exit 1
fi
trap 'rm -rf "$bundle"' EXIT
# Builds, assembles and signs the bundle (with TICKET_PILOT_SIGN_IDENTITY when set, else ad hoc).
./build-app.sh "$bundle"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$bundle/Contents/Info.plist")

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
# The old per-user copy, so that Spotlight and the login item find a single app.
rm -rf "$HOME/Applications/TicketPilot.app"
open "$destination"
echo "Installed $destination (version $version)."
