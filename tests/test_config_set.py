import contextlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path

from ticket_pilot import cli


class ConfigSetTests(unittest.TestCase):
    """`tp config-set`: the skill saves a setting it worked out during a run, the rest of the file kept."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.repo = self.root / "app"
        self.repo.mkdir()
        self.config = self.root / "config.json"
        self.write({
            "jira": {"site": "https://acme.atlassian.net"},
            "repos": [
                {"name": "ios", "path": str(self.repo), "main_branch": "master", "review": "gerrit"},
                {"name": "web", "path": str(self.repo), "main_branch": "main"},
            ],
            "poll_minutes": 2,
        })
        saved = os.environ.get("TICKET_PILOT_CONFIG")
        os.environ["TICKET_PILOT_CONFIG"] = str(self.config)
        self.addCleanup(lambda: os.environ.pop("TICKET_PILOT_CONFIG") if saved is None else os.environ.update(TICKET_PILOT_CONFIG=saved))

    def write(self, data):
        self.config.write_text(json.dumps(data))

    def read(self):
        return json.loads(self.config.read_text())

    def run_cli(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                code = cli.main(list(argv))
            except SystemExit as exit_:
                code = exit_.code
        return code, out.getvalue() + err.getvalue()

    def test_sets_a_repo_setting_and_keeps_the_rest(self):
        code, out = self.run_cli("config-set", "--repo", "ios", "setup_command", "make bootstrap")
        self.assertEqual(code, 0, out)
        data = self.read()
        self.assertEqual(data["repos"][0]["setup_command"], "make bootstrap")
        self.assertEqual(data["repos"][0]["review"], "gerrit")
        self.assertNotIn("setup_command", data["repos"][1])
        self.assertEqual(data["poll_minutes"], 2)
        self.assertTrue(self.config.read_text().endswith("}\n"))

    def test_a_list_setting_gains_the_value_once(self):
        guidelines = self.root / "guidelines"
        guidelines.mkdir()
        for _ in range(2):
            code, out = self.run_cli("config-set", "--repo", "ios", "guidelines", str(guidelines))
            self.assertEqual(code, 0, out)
        self.assertEqual(self.read()["repos"][0]["guidelines"], [str(guidelines)])

    def test_sets_a_top_level_backend_repo(self):
        backend = self.root / "go"
        backend.mkdir()
        code, out = self.run_cli("config-set", "backend.repos", str(backend))
        self.assertEqual(code, 0, out)
        self.assertEqual(self.read()["backend"], {"repos": [str(backend)]})

    def test_refuses_an_unknown_key_and_writes_nothing(self):
        before = self.config.read_text()
        code, out = self.run_cli("config-set", "--repo", "ios", "main_branch", "develop")
        self.assertEqual(code, 2)
        self.assertIn("main_branch", out)
        self.assertEqual(self.config.read_text(), before)

    def test_refuses_an_unknown_repo(self):
        code, out = self.run_cli("config-set", "--repo", "android", "setup_command", "make")
        self.assertEqual(code, 2)
        self.assertIn("android", out)

    def test_refuses_a_value_config_check_would_reject(self):
        before = self.config.read_text()
        code, out = self.run_cli("config-set", "--repo", "ios", "ci_review_prompt", "missing/prompt.md")
        self.assertEqual(code, 2)
        self.assertIn("ci_review_prompt", out)
        self.assertEqual(self.config.read_text(), before)

    def test_a_symlinked_config_is_edited_where_it_points(self):
        target = self.root / "real.json"
        self.config.rename(target)
        self.config.symlink_to(target)
        code, out = self.run_cli("config-set", "--repo", "web", "launch_skill", "run-web")
        self.assertEqual(code, 0, out)
        self.assertTrue(self.config.is_symlink())
        self.assertEqual(json.loads(target.read_text())["repos"][1]["launch_skill"], "run-web")


if __name__ == "__main__":
    unittest.main()
