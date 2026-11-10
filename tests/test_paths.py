import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from ticket_pilot import paths


class PathsTests(unittest.TestCase):
    def test_state_home_uses_env(self):
        with mock.patch.dict(os.environ, {"TICKET_PILOT_HOME": "/tmp/x"}):
            self.assertEqual(paths.state_home(), Path("/tmp/x"))

    def test_state_home_default(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(
                paths.state_home(),
                Path.home() / "Library" / "Application Support" / "ticket-pilot",
            )

    def test_runs_dir_is_created(self):
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.dict(os.environ, {"TICKET_PILOT_HOME": tmp}):
                runs = paths.runs_dir()
                self.assertEqual(runs, Path(tmp) / "runs")
                self.assertTrue(runs.is_dir())

    def test_config_path_uses_env(self):
        with mock.patch.dict(os.environ, {"TICKET_PILOT_CONFIG": "/tmp/c.json"}):
            self.assertEqual(paths.config_path(), Path("/tmp/c.json"))

    def test_config_path_default(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(
                paths.config_path(),
                Path.home() / ".config" / "ticket-pilot" / "config.json",
            )


if __name__ == "__main__":
    unittest.main()
