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
RESOURCES = ROOT / "app" / "Resources"
PLIST = RESOURCES / "Info.plist"
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

    def test_script_builds_signs_and_installs(self):
        self.assertIn("pkill -x TicketPilot", self.text)
        self.assertIn(".TicketPilot.app.new", self.text)
        for expected in (
            "swift build -c release --package-path app --arch arm64 --arch x86_64",
            "codesign --force --sign -",
            'destination="/Applications/TicketPilot.app"',
            'bundle="/Applications/.TicketPilot.app.new"',
            'rm -rf "$HOME/Applications/TicketPilot.app"',
            "[ ! -w /Applications ]",
            "osascript -e 'quit app \"TicketPilot\"'",
        ):
            self.assertIn(expected, self.text)

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

    def test_script_works_from_any_directory_and_avoids_sudo(self):
        self.assertIn('cd "$(dirname "${BASH_SOURCE[0]}")"', self.text)
        code = [l for l in self.text.splitlines() if not l.lstrip().startswith("#")]
        self.assertNotIn("sudo", "\n".join(code))

    def test_without_from_source_it_exits_with_2(self):
        result = subprocess.run(
            ["bash", str(SCRIPT)], capture_output=True, text=True, cwd="/",
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("/ticket-pilot:setup", result.stderr)
        self.assertIn("release", result.stderr)


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


if __name__ == "__main__":
    unittest.main()
