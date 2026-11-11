import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
README = (ROOT / "README.md").read_text()


def section(title):
    match = re.search(r"^## %s\n(.*?)(?=^## |\Z)" % re.escape(title), README, re.S | re.M)
    return match.group(1) if match else None


class ReadmeTests(unittest.TestCase):
    def test_readme_sections(self):
        for title in ("What it does", "Install", "Configure", "Usage", "Safety"):
            self.assertIsNotNone(section(title), title)

    def test_ci_review_replay_is_documented(self):
        replay = section("Replaying your CI review")
        self.assertIsNotNone(replay)
        self.assertIn("ci_review_command", replay)
        self.assertIn("never post, comment or vote anywhere", replay)
        self.assertIn("$TP_REV", replay)

    def test_install_commands(self):
        install = section("Install")
        self.assertIn("claude plugin marketplace add", install)
        self.assertIn("claude plugin install ticket-pilot@ticket-pilot", install)
        self.assertIn("--plugin-dir", install)

    def test_configure_mentions_check(self):
        configure = section("Configure")
        self.assertIn("config.example.json", configure)
        self.assertIn("~/.config/ticket-pilot/config.json", configure)
        self.assertIn("config-check", configure)

    def test_usage_command(self):
        self.assertIn("/ticket-pilot:start <KEY>", section("Usage"))

    def test_safety_states_absolute_rule(self):
        safety = section("Safety")
        self.assertIn("Nothing visible to others without an explicit yes", safety)
        self.assertIn("zero", safety)

    def test_what_it_does_lists_ten_steps(self):
        steps = re.findall(r"^\d+\. ", section("What it does"), re.M)
        self.assertEqual(len(steps), 10)

    def test_menu_bar_app_section(self):
        app = section("Menu bar app")
        self.assertIsNotNone(app)
        self.assertIn("./install.sh --from-source", app)
        self.assertIn("runs/*.json", app)
        self.assertIn("in `app/` inside the state directory", app)
        self.assertIn("never launches `claude` without a click", app)
        self.assertIn("claude mcp list", app)
        self.assertIn("Open at login", app)
        self.assertIn("~/Applications/TicketPilot.app", app)
        self.assertNotRegex(README, r"separate, later component")

    def test_installed_plugin_path_is_documented(self):
        for text in (section("Configure"), section("Usage")):
            self.assertIn("~/.claude/plugins/cache/ticket-pilot/ticket-pilot/<version>/", README)
            self.assertIn("TP_ROOT", text)
        configure = section("Configure")
        self.assertIn("ls -d ~/.claude/plugins/cache/ticket-pilot/ticket-pilot/*/ | tail -1", configure)
        self.assertIn('alias tp="$TP_ROOT/bin/tp"', configure)
        self.assertIn('"$TP_ROOT/config.example.json"', configure)
        self.assertIn("--plugin-dir", configure)

    def test_configuration_reference_covers_every_key(self):
        reference = section("Configuration reference")
        self.assertIsNotNone(reference)
        example = json.loads((ROOT / "config.example.json").read_text())
        keys = set(example)
        for repo in example["repos"]:
            keys.update("repos[]." + key for key in repo)
        keys.update("backend." + key for key in example["backend"])
        keys.update("jira." + key for key in example["jira"])
        keys.update(("poll_minutes", "ready_statuses"))
        for key in keys:
            if key in ("repos", "backend", "jira"):
                continue
            self.assertIn("`%s`" % key, reference, key)


if __name__ == "__main__":
    unittest.main()
