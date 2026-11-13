#!/usr/bin/env bash
# Notarizes a TicketPilot.app signed with a Developer ID Application identity (see build-app.sh), staples
# the ticket to it and writes the zip to share. Sends the app to Apple's notary service; writes only the
# app (the stapled ticket) and the zip.
#
# Usage: TICKET_PILOT_NOTARY_PROFILE=<profile> ./notarize.sh <TicketPilot.app> <TicketPilot.zip>
# The profile is the one saved by `xcrun notarytool store-credentials <profile>`; with
# TICKET_PILOT_NOTARY_KEYCHAIN, it is read from that keychain instead of the default one.
set -euo pipefail

app="${1:-}"
zip="${2:-}"
if [ -z "$app" ] || [ -z "$zip" ]; then
  echo "Usage: TICKET_PILOT_NOTARY_PROFILE=<profile> ./notarize.sh <TicketPilot.app> <TicketPilot.zip>" >&2
  exit 2
fi
profile="${TICKET_PILOT_NOTARY_PROFILE:-}"
if [ -z "$profile" ]; then
  echo "TICKET_PILOT_NOTARY_PROFILE is not set. Save your notary credentials once with:" >&2
  echo "  xcrun notarytool store-credentials <profile>" >&2
  exit 2
fi
keychain=()
if [ -n "${TICKET_PILOT_NOTARY_KEYCHAIN:-}" ]; then
  keychain=(--keychain "$TICKET_PILOT_NOTARY_KEYCHAIN")
fi

# Apple refuses an app without a Developer ID signature, the hardened runtime or a secure timestamp:
# checked here, before the upload.
codesign --verify --strict --deep "$app"
signature=$(codesign -dvv "$app" 2>&1)
if ! grep -q '^Authority=Developer ID Application:' <<<"$signature"; then
  echo "$app is not signed with a Developer ID Application identity: build it with" >&2
  echo "  TICKET_PILOT_SIGN_IDENTITY=\"Developer ID Application: …\" ./build-app.sh $app" >&2
  exit 1
fi
if ! grep -q '^CodeDirectory .*flags=.*runtime' <<<"$signature"; then
  echo "$app is not signed with the hardened runtime." >&2
  exit 1
fi
if ! grep -q '^Timestamp=' <<<"$signature"; then
  echo "$app has no secure timestamp." >&2
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
ditto -c -k --keepParent "$app" "$work/upload.zip"
result=$(xcrun notarytool submit "$work/upload.zip" --keychain-profile "$profile" ${keychain[@]+"${keychain[@]}"} \
  --wait --output-format json)
status=$(/usr/bin/python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("status", ""))' "$result")
id=$(/usr/bin/python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("id", ""))' "$result")
if [ "$status" != "Accepted" ]; then
  echo "Notarization ended with status \"$status\" (submission $id). Apple's log:" >&2
  xcrun notarytool log "$id" --keychain-profile "$profile" ${keychain[@]+"${keychain[@]}"} >&2 || true
  exit 1
fi

xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"

mkdir -p "$(dirname "$zip")"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
echo "Notarized $app (submission $id) and wrote $zip."
