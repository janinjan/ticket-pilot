import os
import plistlib
import struct
import subprocess
import tempfile
import unittest
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "install.sh"
BUILD = ROOT / "build-app.sh"
NOTARIZE = ROOT / "notarize.sh"
RESOURCES = ROOT / "app" / "Resources"
PLIST = RESOURCES / "Info.plist"
ENTITLEMENTS = RESOURCES / "TicketPilot.entitlements"
ICON = RESOURCES / "AppIcon.icns"
ICON_SCRIPT = RESOURCES / "make-icon.sh"


class InstallScriptTests(unittest.TestCase):
    """The script is never run here: it builds an app and installs it under /Applications."""

    def setUp(self):
        self.text = SCRIPT.read_text()

    def test_script_is_valid_bash(self):
        result = subprocess.run(["bash", "-n", str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_script_is_executable_bash_in_strict_mode(self):
        self.assertTrue(os.access(SCRIPT, os.X_OK))
        self.assertTrue(self.text.startswith("#!/usr/bin/env bash\n"))
        self.assertIn("set -euo pipefail", self.text)

    def test_script_builds_with_build_app_then_installs(self):
        self.assertIn("pkill -x TicketPilot", self.text)
        self.assertIn(".TicketPilot.app.new", self.text)
        self.assertLess(self.text.index('./build-app.sh "$bundle"'), self.text.index('mv "$bundle" "$destination"'))
        for expected in (
            'destination="/Applications/TicketPilot.app"',
            'bundle="/Applications/.TicketPilot.app.new"',
            'rm -rf "$HOME/Applications/TicketPilot.app"',
            "[ ! -w /Applications ]",
            "osascript -e 'quit app \"TicketPilot\"'",
        ):
            self.assertIn(expected, self.text)

    def test_script_works_from_any_directory_and_avoids_sudo(self):
        self.assertIn('cd "$(dirname "${BASH_SOURCE[0]}")"', self.text)
        code = [l for l in self.text.splitlines() if not l.lstrip().startswith("#")]
        self.assertNotIn("sudo", "\n".join(code))

    def test_without_from_source_it_exits_with_2(self):
        result = subprocess.run(
            ["bash", str(SCRIPT)], capture_output=True, text=True, cwd="/",
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("https://github.com/janinjan/ticket-pilot/releases", result.stderr)
        self.assertIn("--from-source", result.stderr)



class BuildAppScriptTests(unittest.TestCase):
    """Never run here either: it builds the app with swift and signs it."""

    def setUp(self):
        self.text = BUILD.read_text()

    def test_script_is_executable_valid_bash_in_strict_mode(self):
        self.assertTrue(os.access(BUILD, os.X_OK))
        self.assertTrue(self.text.startswith("#!/usr/bin/env bash\n"))
        self.assertIn("set -euo pipefail", self.text)
        result = subprocess.run(["bash", "-n", str(BUILD)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_without_a_bundle_path_it_exits_with_2(self):
        result = subprocess.run(["bash", str(BUILD)], capture_output=True, text=True, cwd="/")
        self.assertEqual(result.returncode, 2)
        self.assertIn("Usage", result.stderr)

    def test_builds_a_universal_binary(self):
        self.assertIn("swift build -c release --package-path app --arch arm64 --arch x86_64", self.text)

    def test_signs_with_the_identity_and_hardened_runtime_else_ad_hoc(self):
        self.assertIn('if [ -n "${TICKET_PILOT_SIGN_IDENTITY:-}" ]; then', self.text)
        self.assertIn("codesign --force --options runtime --timestamp", self.text)
        self.assertIn("--entitlements app/Resources/TicketPilot.entitlements", self.text)
        self.assertIn('--sign "$TICKET_PILOT_SIGN_IDENTITY" "$bundle"', self.text)
        self.assertIn('codesign --force --sign - "$bundle"', self.text)

    def test_script_copies_the_icon_into_the_bundle_before_signing(self):
        copy = 'cp app/Resources/AppIcon.icns "$bundle/Contents/Resources/"'
        self.assertIn(copy, self.text)
        self.assertIn('mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"', self.text)
        self.assertLess(self.text.index(copy), self.text.index("codesign --force"))

    def plugin_copy_lines(self):
        return [l.strip() for l in self.text.splitlines() if '"$plugin/"' in l and l.strip().startswith("cp ")]

    def test_script_embeds_the_plugin_before_signing(self):
        self.assertIn('plugin="$bundle/Contents/Resources/plugin"', self.text)
        self.assertIn('mkdir -p "$plugin"', self.text)
        copies = self.plugin_copy_lines()
        self.assertEqual(copies, [
            'cp -R .claude-plugin skills agents hooks bin ticket_pilot "$plugin/"',
            'cp LICENSE README.md config.example.json "$plugin/"',
        ])
        for line in copies:
            self.assertLess(self.text.index(line), self.text.index("codesign --force"))

    def test_embedded_plugin_lists_exactly_what_the_plugin_needs(self):
        copied = set()
        for line in self.plugin_copy_lines():
            copied.update(w for w in line.split() if w not in ("cp", "-R", '"$plugin/"'))
        self.assertEqual(copied, {
            ".claude-plugin", "skills", "agents", "hooks", "bin", "ticket_pilot",
            "LICENSE", "README.md", "config.example.json",
        })
        for excluded in ("app", "tests", ".git", ".superpowers", ".github"):
            self.assertNotIn(excluded, copied)
        for name in copied:
            self.assertTrue((ROOT / name).exists(), name)

    def test_embedded_plugin_drops_python_caches(self):
        cleanup = next(l for l in self.text.splitlines() if l.startswith('find "$plugin"'))
        self.assertIn("-name __pycache__", cleanup)
        self.assertIn("-exec rm -rf {} +", cleanup)
        self.assertLess(self.text.index(cleanup), self.text.index("codesign --force"))


class IconTests(unittest.TestCase):
    def test_icon_is_a_committed_icns_file(self):
        self.assertTrue(ICON.is_file())
        self.assertEqual(ICON.read_bytes()[:4], b"icns")

    def test_icon_corners_are_transparent(self):
        with tempfile.TemporaryDirectory() as tmp:
            iconset = Path(tmp) / "AppIcon.iconset"
            subprocess.run(["iconutil", "-c", "iconset", str(ICON), "-o", str(iconset)], check=True)
            data = (iconset / "icon_512x512.png").read_bytes()
        pos, idat, color_type, depth = 8, b"", None, None
        while pos < len(data):
            length, kind = struct.unpack(">I4s", data[pos:pos + 8])
            body = data[pos + 8:pos + 8 + length]
            if kind == b"IHDR":
                depth, color_type = body[8], body[9]
            elif kind == b"IDAT":
                idat += body
            pos += 12 + length
        self.assertEqual((depth, color_type), (8, 6), "expected an 8-bit RGBA PNG")
        # The first pixel of the first row is the top-left corner, whatever the row filter is.
        corner = zlib.decompressobj().decompress(idat, 5)[1:5]
        self.assertEqual(corner[3], 0, "the corner must be fully transparent")

    def test_icon_source_and_generator_are_valid(self):
        self.assertTrue((RESOURCES / "AppIcon.svg").is_file())
        result = subprocess.run(["bash", "-n", str(ICON_SCRIPT)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


class InfoPlistTests(unittest.TestCase):
    def setUp(self):
        with PLIST.open("rb") as handle:
            self.info = plistlib.load(handle)

    def test_bundle_identity(self):
        self.assertEqual(self.info["CFBundleIdentifier"], "dev.ticketpilot.menubar")
        self.assertEqual(self.info["CFBundleExecutable"], "TicketPilot")
        self.assertEqual(self.info["CFBundleName"], "TicketPilot")
        self.assertEqual(self.info["CFBundleIconFile"], "AppIcon")

    def test_menu_bar_only_and_macos_14(self):
        self.assertIs(self.info["LSUIElement"], True)
        self.assertEqual(self.info["LSMinimumSystemVersion"], "14.0")

    def test_version_is_a_placeholder_filled_by_the_installer(self):
        self.assertEqual(self.info["CFBundleShortVersionString"], "__VERSION__")
        self.assertEqual(self.info["CFBundleVersion"], "__VERSION__")

    def test_explains_why_it_sends_apple_events(self):
        # The hardened runtime asks the user before the app drives the terminal: macOS shows this sentence.
        self.assertIn("terminal", self.info["NSAppleEventsUsageDescription"])


class EntitlementsTests(unittest.TestCase):
    def test_only_apple_events_are_entitled(self):
        with ENTITLEMENTS.open("rb") as handle:
            entitlements = plistlib.load(handle)
        self.assertEqual(entitlements, {"com.apple.security.automation.apple-events": True})


class NotarizeScriptTests(unittest.TestCase):
    """Never run against Apple here: only its checks before any upload."""

    def setUp(self):
        self.text = NOTARIZE.read_text()

    def run_script(self, *args, profile=None):
        env = {k: v for k, v in os.environ.items() if not k.startswith("TICKET_PILOT_")}
        if profile:
            env["TICKET_PILOT_NOTARY_PROFILE"] = profile
        return subprocess.run(["bash", str(NOTARIZE), *args], capture_output=True, text=True, cwd="/", env=env)

    def test_script_is_executable_valid_bash_in_strict_mode(self):
        self.assertTrue(os.access(NOTARIZE, os.X_OK))
        self.assertIn("set -euo pipefail", self.text)
        result = subprocess.run(["bash", "-n", str(NOTARIZE)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_without_arguments_or_profile_it_exits_with_2(self):
        self.assertEqual(self.run_script().returncode, 2)
        result = self.run_script("/tmp/TicketPilot.app", "/tmp/TicketPilot.zip")
        self.assertEqual(result.returncode, 2)
        self.assertIn("notarytool store-credentials", result.stderr)

    def test_an_unsigned_app_is_refused_before_any_upload(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "TicketPilot.app"
            (app / "Contents").mkdir(parents=True)
            result = self.run_script(str(app), str(Path(tmp) / "out.zip"), profile="unused")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Notarized", result.stdout)

    def test_checks_the_signature_then_staples_only_an_accepted_app(self):
        upload = self.text.index("notarytool submit")
        for check in ("Authority=Developer ID Application:", "flags=.*runtime", "^Timestamp="):
            self.assertLess(self.text.index(check), upload)
        accepted = self.text.index('if [ "$status" != "Accepted" ]; then')
        self.assertLess(upload, accepted)
        self.assertLess(accepted, self.text.index('xcrun stapler staple "$app"'))
        self.assertIn('spctl --assess --type execute', self.text)


if __name__ == "__main__":
    unittest.main()
