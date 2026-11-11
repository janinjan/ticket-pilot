import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from ticket_pilot import cli, hooks, paths, runs

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class HooksTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self._saved = os.environ.get("TICKET_PILOT_HOME")
        os.environ["TICKET_PILOT_HOME"] = os.path.join(self._tmp.name, "home")
        self.addCleanup(self._restore)
        self.repo = os.path.join(self._tmp.name, "repos", "app")
        os.makedirs(os.path.join(self.repo, "sub"))

    def _restore(self):
        if self._saved is None:
            os.environ.pop("TICKET_PILOT_HOME", None)
        else:
            os.environ["TICKET_PILOT_HOME"] = self._saved

    def event(self, name, session="s1", cwd=None, **extra):
        data = {"session_id": session, "cwd": cwd or self.repo, "hook_event_name": name}
        data.update(extra)
        return data

    def start_prompt(self, key="ABC-1", session="s1", cwd=None):
        return self.event(
            "UserPromptSubmit", session=session, cwd=cwd, prompt="/ticket-pilot:start %s" % key
        )

    def pending_path(self, session="s1"):
        return paths.state_home() / "sessions" / ("%s.json" % session)

    def snapshot_state(self):
        result = {}
        for dirpath, _, filenames in os.walk(str(paths.state_home())):
            for name in filenames:
                path = os.path.join(dirpath, name)
                with open(path, encoding="utf-8") as handle:
                    result[path] = handle.read()
        return result


class BindingTests(HooksTestCase):
    def test_start_prompt_binds_session(self):
        runs.start("ABC-1", "app", self.repo)
        hooks.handle(self.start_prompt(cwd=os.path.join(self.repo, "sub")))
        run = runs.load("ABC-1--app")
        self.assertEqual(run["session_id"], "s1")
        self.assertEqual(
            run["session"],
            {
                "state": "running",
                "last_notification": None,
                "notified_at": None,
                "cwd": os.path.join(self.repo, "sub"),
            },
        )
        self.assertFalse(self.pending_path().exists())

    def test_start_prompt_before_run_exists_writes_pending_record(self):
        hooks.handle(self.start_prompt())
        with open(str(self.pending_path()), encoding="utf-8") as handle:
            pending = json.load(handle)
        self.assertEqual(pending["session_id"], "s1")
        self.assertEqual(pending["key"], "ABC-1")
        self.assertEqual(pending["cwd"], self.repo)
        self.assertIn("created_at", pending)

    def test_start_prompt_key_must_be_a_whole_word(self):
        runs.start("ABC-1", "app", self.repo)
        hooks.handle(self.start_prompt(key="ABC-1x"))
        self.assertIsNone(runs.load("ABC-1--app")["session_id"])
        self.assertFalse(self.pending_path().exists())
        hooks.handle(self.start_prompt(key="ABC-1 please"))
        self.assertEqual(runs.load("ABC-1--app")["session_id"], "s1")

    def test_pending_record_resolves_on_later_event(self):
        hooks.handle(self.start_prompt())
        runs.start("ABC-1", "app", self.repo)
        hooks.handle(self.event("Stop"))
        run = runs.load("ABC-1--app")
        self.assertEqual(run["session_id"], "s1")
        self.assertEqual(run["status"], "waiting")
        self.assertEqual(run["session"]["state"], "waiting")
        self.assertFalse(self.pending_path().exists())

    def test_pending_record_resolves_through_worktree(self):
        worktree = os.path.join(self._tmp.name, "worktrees", "abc-1")
        os.makedirs(worktree)
        hooks.handle(self.start_prompt(cwd=worktree))
        runs.start("ABC-1", "app", self.repo)
        runs.update("ABC-1--app", worktree=worktree)
        hooks.handle(self.event("Notification", cwd=worktree, message="Need input"))
        run = runs.load("ABC-1--app")
        self.assertEqual(run["session_id"], "s1")
        self.assertEqual(run["session"]["last_notification"], "Need input")

    def test_pending_record_kept_while_no_matching_run(self):
        hooks.handle(self.start_prompt())
        runs.start("ABC-2", "app", self.repo)
        hooks.handle(self.event("Stop"))
        self.assertTrue(self.pending_path().exists())
        self.assertIsNone(runs.load("ABC-2--app")["session_id"])

    def test_cwd_prefix_matches_path_components_only(self):
        runs.start("ABC-1", "app", self.repo)
        sibling = self.repo + "-other"
        os.makedirs(sibling)
        hooks.handle(self.start_prompt(cwd=sibling))
        self.assertIsNone(runs.load("ABC-1--app")["session_id"])

    def test_unrelated_session_is_ignored(self):
        runs.start("ABC-1", "app", self.repo)
        hooks.handle(self.start_prompt())
        before = self.snapshot_state()
        for name, extra in (
            ("UserPromptSubmit", {"prompt": "hello"}),
            ("Stop", {}),
            ("Notification", {"message": "hi"}),
            ("SessionStart", {}),
            ("PreToolUse", {}),
        ):
            hooks.handle(self.event(name, session="other", **extra))
        self.assertEqual(self.snapshot_state(), before)

    def test_unsafe_session_id_is_ignored(self):
        hooks.handle(self.start_prompt(session="../escape"))
        self.assertEqual(self.snapshot_state(), {})


class FixRoundOneTests(HooksTestCase):
    def test_new_start_prompt_rebinds_session_to_other_run(self):
        runs.start("ABC-1", "app", self.repo)
        hooks.handle(self.start_prompt("ABC-1"))
        runs.set_waiting("ABC-1--app", "go", "plan ready")
        before = runs.load("ABC-1--app")
        runs.start("ABC-2", "app", self.repo)
        hooks.handle(self.start_prompt("ABC-2"))
        after = runs.load("ABC-1--app")
        self.assertIsNone(after["session_id"])
        for field in ("status", "waiting", "session", "step"):
            self.assertEqual(after[field], before[field], field)
        self.assertEqual(runs.load("ABC-2--app")["session_id"], "s1")

    def test_new_start_prompt_without_run_unbinds_and_writes_pending(self):
        runs.start("ABC-1", "app", self.repo)
        hooks.handle(self.start_prompt("ABC-1"))
        hooks.handle(self.start_prompt("ABC-2"))
        self.assertIsNone(runs.load("ABC-1--app")["session_id"])
        with open(str(self.pending_path()), encoding="utf-8") as handle:
            self.assertEqual(json.load(handle)["key"], "ABC-2")

    def test_same_start_prompt_keeps_binding(self):
        runs.start("ABC-1", "app", self.repo)
        hooks.handle(self.start_prompt("ABC-1"))
        runs.set_waiting("ABC-1--app", "go", "plan ready")
        hooks.handle(self.start_prompt("ABC-1"))
        run = runs.load("ABC-1--app")
        self.assertEqual(run["session_id"], "s1")
        self.assertEqual(run["status"], "running")
        self.assertIsNone(run["waiting"])
        self.assertFalse(self.pending_path().exists())

    def test_unrelated_session_does_not_create_state_home(self):
        for name, extra in (
            ("UserPromptSubmit", {"prompt": "hello"}),
            ("Stop", {}),
            ("Notification", {"message": "hi"}),
            ("SessionStart", {}),
        ):
            hooks.handle(self.event(name, session="other", **extra))
        self.assertFalse(paths.state_home().exists())

    def test_stale_pending_record_is_dropped(self):
        hooks.handle(self.start_prompt())
        with open(str(self.pending_path()), encoding="utf-8") as handle:
            record = json.load(handle)
        record["created_at"] = "2000-01-01T00:00:00Z"
        with open(str(self.pending_path()), "w", encoding="utf-8") as handle:
            json.dump(record, handle)
        runs.start("ABC-1", "app", self.repo)
        hooks.handle(self.event("Stop"))
        self.assertFalse(self.pending_path().exists())
        self.assertIsNone(runs.load("ABC-1--app")["session_id"])

    def test_now_is_public(self):
        self.assertRegex(runs.now(), r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


class BoundSessionTests(HooksTestCase):
    def setUp(self):
        super().setUp()
        runs.start("ABC-1", "app", self.repo)
        hooks.handle(self.start_prompt())

    def test_stop_marks_waiting_for_input(self):
        hooks.handle(self.event("Stop"))
        run = runs.load("ABC-1--app")
        self.assertEqual(run["status"], "waiting")
        self.assertEqual(run["waiting"]["kind"], "input")
        self.assertEqual(run["waiting"]["text"], "")
        self.assertIn("since", run["waiting"])
        self.assertEqual(run["session"]["state"], "waiting")

    def test_events_store_the_session_cwd(self):
        sub = os.path.join(self.repo, "sub")
        os.makedirs(sub, exist_ok=True)
        self.assertEqual(runs.load("ABC-1--app")["session"]["cwd"], self.repo)
        hooks.handle(self.event("Stop", cwd=sub))
        self.assertEqual(runs.load("ABC-1--app")["session"]["cwd"], sub)
        hooks.handle(self.event("SessionEnd", cwd=self.repo))
        self.assertEqual(runs.load("ABC-1--app")["session"]["cwd"], self.repo)

    def test_stop_does_not_override_explicit_waiting(self):
        runs.set_waiting("ABC-1--app", "go", "plan ready")
        hooks.handle(self.event("Stop"))
        run = runs.load("ABC-1--app")
        self.assertEqual(run["waiting"]["kind"], "go")
        self.assertEqual(run["waiting"]["text"], "plan ready")

    def test_stop_keeps_done_run_done(self):
        runs.set_done("ABC-1--app")
        hooks.handle(self.event("Stop"))
        run = runs.load("ABC-1--app")
        self.assertEqual(run["status"], "done")
        self.assertEqual(run["waiting"]["kind"], "report")

    def test_prompt_after_wait_resumes_running(self):
        runs.set_waiting("ABC-1--app", "go", "plan ready")
        hooks.handle(self.event("UserPromptSubmit", prompt="go"))
        run = runs.load("ABC-1--app")
        self.assertEqual(run["status"], "running")
        self.assertIsNone(run["waiting"])
        self.assertEqual(run["session"]["state"], "running")

    def test_prompt_on_done_run_keeps_done(self):
        runs.set_done("ABC-1--app")
        hooks.handle(self.event("UserPromptSubmit", prompt="thanks"))
        run = runs.load("ABC-1--app")
        self.assertEqual(run["status"], "done")
        self.assertEqual(run["session"]["state"], "running")

    def test_notification_records_message(self):
        hooks.handle(self.event("Notification", message="Claude needs your permission"))
        session = runs.load("ABC-1--app")["session"]
        self.assertEqual(session["last_notification"], "Claude needs your permission")
        self.assertIsNotNone(session["notified_at"])

    def test_session_start_marks_running(self):
        hooks.handle(self.event("Stop"))
        hooks.handle(self.event("SessionStart", source="resume"))
        run = runs.load("ABC-1--app")
        self.assertEqual(run["session"]["state"], "running")
        self.assertEqual(run["status"], "waiting")


class SessionEndTests(HooksTestCase):
    def setUp(self):
        super().setUp()
        runs.start("ABC-1", "app", self.repo)
        hooks.handle(self.start_prompt())

    def test_session_end_marks_session_ended(self):
        hooks.handle(self.event("Stop"))
        hooks.handle(self.event("SessionEnd", reason="other"))
        run = runs.load("ABC-1--app")
        self.assertEqual(run["session"]["state"], "ended")
        self.assertRegex(run["session"]["ended_at"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        self.assertEqual(run["status"], "waiting")
        self.assertEqual(run["waiting"]["kind"], "input")

    def test_session_end_for_unknown_session_is_ignored(self):
        before = self.snapshot_state()
        hooks.handle(self.event("SessionEnd", session="other"))
        self.assertEqual(self.snapshot_state(), before)

    def test_session_end_never_binds_a_pending_session(self):
        hooks.handle(self.start_prompt(key="ABC-2", session="s2"))
        self.assertTrue(self.pending_path("s2").exists())
        hooks.handle(self.event("SessionEnd", session="s2"))
        self.assertIsNone(runs.find_by_session("s2"))
        self.assertTrue(self.pending_path("s2").exists())

    def test_resume_brings_session_back_to_running(self):
        hooks.handle(self.event("SessionEnd"))
        hooks.handle(self.event("SessionStart", source="resume"))
        session = runs.load("ABC-1--app")["session"]
        self.assertEqual(session["state"], "running")
        self.assertNotIn("ended_at", session)

    def test_prompt_after_end_brings_session_back_to_running(self):
        hooks.handle(self.event("SessionEnd"))
        hooks.handle(self.event("UserPromptSubmit", prompt="continue"))
        session = runs.load("ABC-1--app")["session"]
        self.assertEqual(session["state"], "running")
        self.assertNotIn("ended_at", session)


class CliHookTests(HooksTestCase):
    def run_hook(self, stdin_text):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(sys, "stdin", io.StringIO(stdin_text)):
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                try:
                    code = cli.main(["hook"])
                except SystemExit as exit_:
                    code = exit_.code
        return code, out.getvalue(), err.getvalue()

    def test_cli_hook_never_fails(self):
        for payload in ("not json", "", "[]", "{}", '{"session_id": 3}', "null"):
            self.assertEqual(self.run_hook(payload), (0, "", ""), payload)

    def test_cli_hook_ignores_extra_args(self):
        for extra in (["foo", "bar"], ["--unknown"], ["x", "--flag", "-v"]):
            out, err = io.StringIO(), io.StringIO()
            with mock.patch.object(sys, "stdin", io.StringIO("{}")):
                with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                    try:
                        code = cli.main(["hook"] + extra)
                    except SystemExit as exit_:
                        code = exit_.code
            self.assertEqual((code, out.getvalue(), err.getvalue()), (0, "", ""), extra)

    def test_cli_hook_swallows_exceptions(self):
        with mock.patch.object(hooks, "handle", side_effect=RuntimeError("boom")):
            self.assertEqual(self.run_hook(json.dumps(self.event("Stop"))), (0, "", ""))

    def test_cli_hook_handles_event(self):
        runs.start("ABC-1", "app", self.repo)
        code, out, err = self.run_hook(json.dumps(self.start_prompt()))
        self.assertEqual((code, err), (0, ""))
        self.assertIn("before asking the user anything", json.loads(out)["hookSpecificOutput"]["additionalContext"])
        self.assertEqual(runs.load("ABC-1--app")["session_id"], "s1")

    def test_bin_tp_hook_is_silent_on_garbage(self):
        result = subprocess.run(
            [os.path.join(ROOT, "bin", "tp"), "hook"],
            input=b"\x00garbage",
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=dict(os.environ),
        )
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))


class LanguageReminderTests(HooksTestCase):
    LANGUAGE = (
        "ticket-pilot: write every message to the user in the run's language (fr), "
        "including summaries after tool or agent output; translate tool output, "
        "never paste it in another language."
    )
    AUTONOMY = (
        "ticket-pilot: before asking the user anything, look for the answer yourself "
        "(the app you drive, the repo, the config, the tools such as the proxy CLI and the simulator; "
        "retry tooling failures with tp run-shell or the repo's build skill). "
        "Ask only for a decision that is the user's, an action visible to others, "
        "or what you genuinely cannot obtain \u2014 and say what you tried."
    )

    def expected(self, text):
        return {"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": text}}

    def run_hook(self, payload):
        out = io.StringIO()
        with mock.patch.object(sys, "stdin", io.StringIO(payload)):
            with contextlib.redirect_stdout(out):
                code = cli.main(["hook"])
        return code, out.getvalue()

    def bind(self, language):
        runs.start("ABC-1", "app", self.repo)
        if language:
            runs.update("ABC-1--app", language=language)
        hooks.handle(self.start_prompt())

    def test_bound_run_with_language_prints_exact_json(self):
        self.bind("fr")
        code, out = self.run_hook(json.dumps(self.event("UserPromptSubmit", prompt="continue")))
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out), self.expected(self.LANGUAGE + " " + self.AUTONOMY))

    def test_run_without_language_only_has_the_autonomy_sentence(self):
        self.bind(None)
        code, out = self.run_hook(json.dumps(self.event("UserPromptSubmit", prompt="x")))
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out), self.expected(self.AUTONOMY))

    def test_done_run_is_silent(self):
        self.bind("fr")
        runs.update("ABC-1--app", status="done")
        self.assertEqual(self.run_hook(json.dumps(self.event("UserPromptSubmit", prompt="x"))), (0, ""))

    def test_unbound_session_is_silent(self):
        self.bind("fr")
        payload = self.event("UserPromptSubmit", session="other", prompt="x")
        self.assertEqual(self.run_hook(json.dumps(payload)), (0, ""))

    def test_other_events_are_silent(self):
        self.bind("fr")
        for name in ("Stop", "Notification", "SessionStart", "SessionEnd"):
            self.assertEqual(self.run_hook(json.dumps(self.event(name))), (0, ""), name)

    def test_malformed_input_is_silent(self):
        self.bind("fr")
        for payload in ("not json", "", "[]", "null"):
            self.assertEqual(self.run_hook(payload), (0, ""), payload)


class HooksJsonTests(unittest.TestCase):
    def test_hooks_json_lists_five_events(self):
        with open(os.path.join(ROOT, "hooks", "hooks.json"), encoding="utf-8") as handle:
            data = json.load(handle)
        events = data["hooks"]
        self.assertEqual(
            sorted(events),
            ["Notification", "SessionEnd", "SessionStart", "Stop", "UserPromptSubmit"],
        )
        for name, groups in events.items():
            self.assertEqual(
                groups,
                [{"hooks": [{"type": "command", "command": '"${CLAUDE_PLUGIN_ROOT}/bin/tp" hook'}]}],
                name,
            )


if __name__ == "__main__":
    unittest.main()
