import contextlib
import io
import json
import os
import tempfile
import unittest

from ticket_pilot import cli, paths, runs


class RunsTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self._saved = os.environ.get("TICKET_PILOT_HOME")
        os.environ["TICKET_PILOT_HOME"] = self._tmp.name
        self.addCleanup(self._restore)

    def _restore(self):
        if self._saved is None:
            os.environ.pop("TICKET_PILOT_HOME", None)
        else:
            os.environ["TICKET_PILOT_HOME"] = self._saved

    def run_cli(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                code = cli.main(list(argv))
            except SystemExit as exit_:
                code = exit_.code
        return code, out.getvalue(), err.getvalue()


class RunsTests(RunsTestCase):
    def test_same_key_two_repos_do_not_collide(self):
        first = runs.start("ABC-1", "app", "/tmp/app")
        second = runs.start("ABC-1", "api", "/tmp/api")
        self.assertNotEqual(first["id"], second["id"])
        self.assertEqual(runs.load("ABC-1--app")["repo_path"], "/tmp/app")
        self.assertEqual(runs.load("ABC-1--api")["repo_path"], "/tmp/api")

    def test_start_creates_expected_schema(self):
        run = runs.start("ABC-1", "app", "/tmp/app")
        self.assertEqual(run["id"], "ABC-1--app")
        self.assertEqual(run["step"], 1)
        self.assertEqual(run["step_name"], "understand")
        self.assertEqual(run["status"], "running")
        self.assertIsNone(run["session"])
        self.assertIsNone(run["session_id"])
        self.assertEqual(run["requests"], [])
        self.assertEqual(len(run["history"]), 1)

    def test_start_is_idempotent(self):
        first = runs.start("ABC-1", "app", "/tmp/app")
        runs.set_step(first["id"], 3, "research")
        again = runs.start("ABC-1", "app", "/tmp/app")
        self.assertEqual(again["step"], 3)
        self.assertEqual(len(again["history"]), 2)

    def test_set_step_closes_previous_history_entry(self):
        run = runs.start("ABC-1", "app", "/tmp/app")
        run = runs.set_step(run["id"], 2, "prepare")
        self.assertIn("ended_at", run["history"][0])
        self.assertNotIn("ended_at", run["history"][1])
        self.assertEqual(run["history"][1]["step"], 2)
        self.assertEqual(run["step_name"], "prepare")

    def test_set_step_on_the_open_current_step_keeps_one_entry(self):
        run = runs.start("ABC-1", "app", "/tmp/app")
        started_at = run["history"][0]["started_at"]
        runs.set_waiting(run["id"], "go", "Ready?")
        run = runs.set_step(run["id"], 1, "understand")
        self.assertEqual(run["history"], [{"step": 1, "started_at": started_at}])
        self.assertEqual(run["status"], "running")
        self.assertIsNone(run["waiting"])

    def test_set_step_on_a_closed_current_step_opens_a_new_entry(self):
        run = runs.start("ABC-1", "app", "/tmp/app")
        run["history"][-1]["ended_at"] = run["history"][-1]["started_at"]
        runs.save(run)
        run = runs.set_step(run["id"], 1, "understand")
        self.assertEqual(len(run["history"]), 2)
        self.assertEqual(run["history"][1]["step"], 1)
        self.assertNotIn("ended_at", run["history"][1])

    def test_set_waiting_rejects_the_hook_only_input_kind(self):
        run = runs.start("ABC-1", "app", "/tmp/app")
        self.assertNotIn("input", runs.WAIT_KINDS)
        with self.assertRaises(ValueError):
            runs.set_waiting(run["id"], "input", "")
        code, _, _ = self.run_cli("run-wait", "ABC-1--app", "input", "")
        self.assertNotEqual(code, 0)

    def test_waiting_then_step_clears_waiting(self):
        run = runs.start("ABC-1", "app", "/tmp/app")
        run = runs.set_waiting(run["id"], "go", "Ready?")
        self.assertEqual(run["status"], "waiting")
        self.assertEqual(run["waiting"]["kind"], "go")
        self.assertEqual(run["waiting"]["text"], "Ready?")
        self.assertIn("since", run["waiting"])
        run = runs.set_step(run["id"], 2, "prepare")
        self.assertEqual(run["status"], "running")
        self.assertIsNone(run["waiting"])

    def test_set_done(self):
        run = runs.start("ABC-1", "app", "/tmp/app")
        run = runs.set_done(run["id"])
        self.assertEqual(run["status"], "done")
        self.assertEqual(run["waiting"]["kind"], "report")

    def test_set_waiting_rejects_unknown_kind(self):
        run = runs.start("ABC-1", "app", "/tmp/app")
        with self.assertRaises(ValueError):
            runs.set_waiting(run["id"], "nope", "x")

    def test_corrupted_file_loads_as_none(self):
        (paths.runs_dir() / "ABC-1--app.json").write_text("{not json")
        self.assertIsNone(runs.load("ABC-1--app"))

    def test_load_missing_is_none(self):
        self.assertIsNone(runs.load("missing--app"))

    def test_save_is_atomic(self):
        run = runs.start("ABC-1", "app", "/tmp/app")
        runs.save(run)
        self.assertEqual(sorted(p.name for p in paths.runs_dir().iterdir()), ["ABC-1--app.json"])

    def test_update_fields(self):
        run = runs.start("ABC-1", "app", "/tmp/app")
        run = runs.update(run["id"], worktree="/w", branch="b", jira_line=True)
        self.assertEqual(run["worktree"], "/w")
        self.assertEqual(runs.load(run["id"])["branch"], "b")

    def test_bind_and_find_by_session(self):
        run = runs.start("ABC-1", "app", "/tmp/app")
        runs.start("ABC-2", "app", "/tmp/app")
        runs.bind_session(run["id"], "sess-1")
        self.assertEqual(runs.find_by_session("sess-1")["id"], run["id"])
        self.assertIsNone(runs.find_by_session("other"))

    def test_step_names_are_ten(self):
        self.assertEqual(len(runs.STEP_NAMES), 10)
        self.assertEqual(runs.STEP_NAMES[0], "understand")
        self.assertEqual(runs.STEP_NAMES[-1], "report")

    def test_key_pattern_is_shared_with_hooks(self):
        from ticket_pilot import hooks
        self.assertEqual(runs.KEY_PATTERN, r"[A-Z][A-Z0-9]+-\d+")
        self.assertIn(runs.KEY_PATTERN, hooks.START_PROMPT.pattern)

    def test_run_id_rejects_invalid_key_or_repo(self):
        for key, repo in (
            ("abc-1", "app"),
            ("ABC-1x", "app"),
            ("../ABC-1", "app"),
            ("ABC-1", "../app"),
            ("ABC-1", "a/b"),
            ("ABC-1", ""),
        ):
            with self.assertRaises(ValueError, msg=(key, repo)):
                runs.run_id(key, repo)
            with self.assertRaises(ValueError, msg=(key, repo)):
                runs.start(key, repo, "/tmp/app")
        self.assertEqual(list(paths.state_home().rglob("*.json")), [])

    def test_run_id_accepts_valid_key_and_repo(self):
        self.assertEqual(runs.run_id("AB2-10", "my.app_1-x"), "AB2-10--my.app_1-x")


class RunsCliTests(RunsTestCase):
    def test_cli_run_start_rejects_invalid_key(self):
        code, out, err = self.run_cli("run-start", "abc-1", "app", "/tmp/app")
        self.assertEqual((code, out), (2, ""))
        self.assertIn("invalid ticket key", err)
        self.assertEqual(runs.existing_runs(), [])

    def test_cli_run_start_rejects_invalid_repo(self):
        code, out, err = self.run_cli("run-start", "ABC-1", "../app", "/tmp/app")
        self.assertEqual((code, out), (2, ""))
        self.assertIn("invalid repo name", err)
        self.assertEqual(runs.existing_runs(), [])

    def test_cli_run_show_prints_json(self):
        code, out, _ = self.run_cli("run-start", "ABC-1", "app", "/tmp/app")
        self.assertEqual(code, 0)
        self.assertEqual(out.strip(), "ABC-1--app")
        code, out, _ = self.run_cli("run-show", "ABC-1--app")
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["key"], "ABC-1")

    def test_cli_step_wait_done_set(self):
        self.run_cli("run-start", "ABC-1", "app", "/tmp/app")
        self.assertEqual(self.run_cli("run-step", "ABC-1--app", "5")[0], 0)
        self.assertEqual(runs.load("ABC-1--app")["step_name"], "implement")
        self.assertEqual(self.run_cli("run-wait", "ABC-1--app", "question", "Which one?")[0], 0)
        self.assertEqual(runs.load("ABC-1--app")["waiting"]["text"], "Which one?")
        self.assertEqual(
            self.run_cli("run-set", "ABC-1--app", "--branch", "b", "--jira-line", "no")[0], 0
        )
        run = runs.load("ABC-1--app")
        self.assertEqual(run["branch"], "b")
        self.assertIs(run["jira_line"], False)
        self.assertEqual(self.run_cli("run-done", "ABC-1--app")[0], 0)
        self.assertEqual(runs.load("ABC-1--app")["status"], "done")

    def test_cli_unknown_run_exits_2(self):
        for argv in (
            ("run-show", "nope--x"),
            ("run-step", "nope--x", "2"),
            ("run-wait", "nope--x", "go", "t"),
            ("run-done", "nope--x"),
            ("run-set", "nope--x", "--branch", "b"),
        ):
            code, _, err = self.run_cli(*argv)
            self.assertEqual(code, 2, argv)
            self.assertIn("unknown run: nope--x", err)

    def test_cli_wait_rejects_bad_kind(self):
        self.run_cli("run-start", "ABC-1", "app", "/tmp/app")
        code, _, err = self.run_cli("run-wait", "ABC-1--app", "bogus", "t")
        self.assertEqual(code, 2)
        self.assertTrue(err)

    def test_cli_step_rejects_out_of_range(self):
        self.run_cli("run-start", "ABC-1", "app", "/tmp/app")
        code, _, _ = self.run_cli("run-step", "ABC-1--app", "11")
        self.assertEqual(code, 2)

    def test_cli_set_requests_replaces_the_list(self):
        self.run_cli("run-start", "ABC-1", "app", "/tmp/app")
        self.run_cli("run-set", "ABC-1--app", "--request", "old")
        code, _, _ = self.run_cli(
            "run-set", "ABC-1--app", "--request", "Show the distance", "--request", "Hide it when empty"
        )
        self.assertEqual(code, 0)
        self.assertEqual(
            runs.load("ABC-1--app")["requests"], ["Show the distance", "Hide it when empty"]
        )

    def test_cli_run_list_prints_every_run(self):
        self.assertEqual(self.run_cli("run-list"), (0, "", ""))
        self.run_cli("run-start", "ABC-1", "app", "/tmp/app")
        self.run_cli("run-start", "ABC-2", "api", "/tmp/api")
        self.run_cli("run-step", "ABC-2--api", "3")
        self.run_cli("run-set", "ABC-2--api", "--worktree", "/w")
        self.run_cli("run-done", "ABC-1--app")
        code, out, _ = self.run_cli("run-list")
        self.assertEqual(code, 0)
        self.assertEqual(
            out.splitlines(),
            ["ABC-1--app done step 1 understand -", "ABC-2--api running step 3 research /w"],
        )

    def test_cli_set_requires_a_flag(self):
        self.run_cli("run-start", "ABC-1", "app", "/tmp/app")
        code, _, _ = self.run_cli("run-set", "ABC-1--app")
        self.assertEqual(code, 2)


if __name__ == "__main__":
    unittest.main()
