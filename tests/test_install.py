import os
import plistlib
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "install.sh"
PLIST = ROOT / "app" / "Resources" / "Info.plist"


class InstallScriptTests(unittest.TestCase):
    """The script is never run here: it builds an app and installs it under ~/Applications."""

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
            '"$HOME/Applications/TicketPilot.app"',
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
        self.assertIn("/ticket-pilot:setup", result.stderr)
        self.assertIn("release", result.stderr)


class InfoPlistTests(unittest.TestCase):
    def setUp(self):
        with PLIST.open("rb") as handle:
            self.info = plistlib.load(handle)

    def test_bundle_identity(self):
        self.assertEqual(self.info["CFBundleIdentifier"], "dev.ticketpilot.menubar")
        self.assertEqual(self.info["CFBundleExecutable"], "TicketPilot")
        self.assertEqual(self.info["CFBundleName"], "TicketPilot")

    def test_menu_bar_only_and_macos_14(self):
        self.assertIs(self.info["LSUIElement"], True)
        self.assertEqual(self.info["LSMinimumSystemVersion"], "14.0")

    def test_version_is_a_placeholder_filled_by_the_installer(self):
        self.assertEqual(self.info["CFBundleShortVersionString"], "__VERSION__")
        self.assertEqual(self.info["CFBundleVersion"], "__VERSION__")


if __name__ == "__main__":
    unittest.main()
