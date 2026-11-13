# Releasing the menu bar app

For maintainers: how the app is signed, notarized and published. Users install it from the [releases](https://github.com/janinjan/ticket-pilot/releases) or with `./install.sh --from-source` (see the README).

## Build and sign

`./build-app.sh <path/to/TicketPilot.app>` builds the app (what `install.sh` runs). With `TICKET_PILOT_SIGN_IDENTITY` set to a code signing identity (its name or its SHA-1, see `security find-identity -v -p codesigning`), it signs with that identity, the hardened runtime, a secure timestamp and `app/Resources/TicketPilot.entitlements`. The only entitlement is Apple Events: the app drives Ghostty with `osascript`, and macOS asks the user once, with the sentence of `NSAppleEventsUsageDescription` in `app/Resources/Info.plist`. Without the variable, the app is signed ad hoc.

To share a build, sign it with a "Developer ID Application" identity:

```sh
TICKET_PILOT_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build-app.sh dist/TicketPilot.app
```

`codesign` needs the identity's private key without a prompt. When the login keychain asks for a password it does not accept, keep the identity in a keychain of its own, unlocked, with the key allowed for `codesign` (`security import … -T /usr/bin/codesign`, then `security set-key-partition-list -S apple-tool:,apple:,codesign: -s`), and add that keychain to the search list.

## Notarize

Save the notary credentials once, with an App Store Connect API key (App Store Connect › Users and Access › Integrations › Team Keys, access Developer):

```sh
xcrun notarytool store-credentials <profile> --key AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER_ID>
```

Then:

```sh
TICKET_PILOT_NOTARY_PROFILE=<profile> ./notarize.sh dist/TicketPilot.app dist/TicketPilot.zip
```

`notarize.sh` refuses an app without the Developer ID signature, the hardened runtime or the timestamp before sending anything. It waits for Apple's answer (and prints Apple's log when it is not "Accepted"), staples the ticket, checks it with `spctl` and writes the zip. It sends the app to Apple's notary service and writes only the app and the zip. With `TICKET_PILOT_NOTARY_KEYCHAIN`, the profile is read from that keychain.

## Release on GitHub

On a `v*` tag, the Release workflow (`.github/workflows/release.yml`) does the same on GitHub and attaches `TicketPilot-<version>.zip` to the tag's release. It stops when the tag is not the version of `.claude-plugin/plugin.json`.

It runs in the `release` environment, which must require your approval (Settings › Environments › release › Required reviewers, deployment tags `v*`): GitHub pauses the job until you approve it, so no one else can sign an app with your identity. The environment holds the secrets:

- `DEVELOPER_ID_P12_BASE64` and `DEVELOPER_ID_P12_PASSWORD`: the Developer ID identity, as a base64 `.p12`, and its password;
- `NOTARY_KEY_P8_BASE64`, `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID`: the App Store Connect API key.

The job imports them into a temporary keychain, deleted at the end.

To release a version:

1. Bump `version` in `.claude-plugin/plugin.json` (commit `chore: release X.Y.Z`) on a branch, push the branch and wait for the CI to pass.
2. Merge into `main`, then tag and push: `git tag vX.Y.Z && git push origin main vX.Y.Z`.
3. Approve the `release` deployment on the workflow run.
