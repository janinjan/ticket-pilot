import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

from ticket_pilot import cli, config

ROOT = Path(__file__).resolve().parent.parent


def write_json(directory, data, name="config.json"):
    path = Path(directory) / name
    path.write_text(json.dumps(data))
    return path


def minimal_repo(name, path, review="github"):
    return {
        "name": name,
        "path": str(path),
        "main_branch": "main",
        "review": review,
        "match": {"title_prefixes": [], "labels": [], "components": []},
    }


class ConfigTests(unittest.TestCase):
    def test_defaults_applied(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = config.load(write_json(tmp, {"repos": []}))
        self.assertEqual(cfg["max_commit_lines"], 999)
        self.assertEqual(cfg["poll_minutes"], 5)
        self.assertEqual(cfg["ready_statuses"], ["To Start"])
        self.assertEqual(cfg["generated_globs"], [])
        self.assertEqual(cfg["snapshot_globs"], ["**/__Snapshots__/**"])

    def test_missing_file_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = config.load(Path(tmp) / "absent.json")
            problems = config.validate(cfg)
        self.assertTrue(cfg["_missing"])
        self.assertTrue(any("config file not found" in p for p in problems))

    def test_repo_path_must_exist(self):
        with tempfile.TemporaryDirectory() as tmp:
            missing = Path(tmp) / "nope"
            cfg = config.load(write_json(tmp, {"repos": [minimal_repo("ios", missing)]}))
            problems = config.validate(cfg)
        self.assertIn("repos[ios].path does not exist: %s" % missing, problems)

    def test_existing_repo_path_is_ok(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = config.load(write_json(tmp, {"repos": [minimal_repo("ios", tmp)]}))
            self.assertEqual(config.validate(cfg), [])

    def test_review_must_be_gerrit_or_github(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = config.load(
                write_json(tmp, {"repos": [minimal_repo("ios", tmp, review="svn")]})
            )
            problems = config.validate(cfg)
        self.assertTrue(any("repos[ios].review" in p for p in problems))

    def test_repo_by_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = config.load(write_json(tmp, {"repos": [minimal_repo("ios", tmp)]}))
        self.assertEqual(config.repo_by_name(cfg, "ios")["name"], "ios")
        self.assertIsNone(config.repo_by_name(cfg, "web"))

    def test_example_config_is_valid_except_paths(self):
        cfg = config.load(ROOT / "config.example.json")
        problems = config.validate(cfg)
        self.assertTrue(problems)
        for problem in problems:
            self.assertIn("does not exist", problem)


class MalformedShapeTests(unittest.TestCase):
    def check(self, data, expected):
        with tempfile.TemporaryDirectory() as tmp:
            path = write_json(tmp, data)
            problems = config.validate(config.load(path))
            self.assertTrue(
                any(expected in p for p in problems), (expected, problems)
            )
            out = io.StringIO()
            with mock.patch.dict(os.environ, {"TICKET_PILOT_CONFIG": str(path)}):
                with redirect_stdout(out):
                    code = cli.main(["config-check"])
            self.assertEqual(code, 2)

    def test_top_level_array(self):
        self.check([], "JSON object")

    def test_backend_not_object(self):
        self.check({"repos": [], "backend": "x"}, "backend must be an object")

    def test_backend_falsy_non_object(self):
        self.check({"repos": [], "backend": []}, "backend must be an object")

    def test_repo_name_not_string(self):
        for name in (["ios"], {"a": 1}, 5):
            with tempfile.TemporaryDirectory() as tmp:
                repo = minimal_repo("ios", tmp)
                repo["name"] = name
                self.check({"repos": [repo]}, "repos[0].name must be a non-empty string")

    def test_repo_name_must_match_run_pattern(self):
        for name in ("my repo", "a/b", "ios;rm"):
            with tempfile.TemporaryDirectory() as tmp:
                self.check(
                    {"repos": [minimal_repo(name, tmp)]},
                    "repos[0].name must match ^[A-Za-z0-9._-]+$",
                )

    def test_backend_repos_not_list(self):
        self.check(
            {"repos": [], "backend": {"repos": "abc"}},
            "backend.repos must be a list",
        )

    def test_backend_api_docs_not_list(self):
        self.check(
            {"repos": [], "backend": {"api_docs": "abc"}},
            "backend.api_docs must be a list",
        )

    def test_repo_path_not_string(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = minimal_repo("ios", tmp)
            repo["path"] = 123
            self.check({"repos": [repo]}, "repos[ios].path must be a string")

    def test_repo_not_object(self):
        self.check({"repos": ["ios"]}, "repos[0] must be an object")

    def test_repo_by_name_skips_non_dicts(self):
        self.assertIsNone(config.repo_by_name({"repos": ["ios", 1]}, "ios"))

    def test_duplicate_repo_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            repos = [minimal_repo("ios", tmp), minimal_repo("ios", tmp)]
            self.check({"repos": repos}, "repos[ios].name is duplicated")

    def test_missing_main_branch(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = minimal_repo("ios", tmp)
            del repo["main_branch"]
            self.check({"repos": [repo]}, "repos[ios].main_branch is required")

    def test_max_commit_lines_rejects_bad_values(self):
        for value in (0, -5, True, "10"):
            self.check({"repos": [], "max_commit_lines": value}, "max_commit_lines")


class OptionalKeyTests(unittest.TestCase):
    STRING_KEYS = (
        "sync_command", "reviewer_agent", "auditor_agent", "terminal_app", "permission_mode", "git_client",
    )
    REPO_STRING_KEYS = (
        "setup_command", "ci_review_prompt", "ci_review_command", "launch_skill", "sync_command", "editor",
    )

    def problems_for(self, data):
        with tempfile.TemporaryDirectory() as tmp:
            return config.validate(config.load(write_json(tmp, data)))

    def test_top_level_optional_keys_must_be_strings(self):
        for key in self.STRING_KEYS:
            problems = self.problems_for({"repos": [], key: 5})
            self.assertIn("%s must be a string" % key, problems)

    def test_top_level_optional_keys_accept_strings(self):
        data = {"repos": []}
        for key in self.STRING_KEYS:
            data[key] = "value"
        self.assertEqual(self.problems_for(data), [])

    def test_repo_optional_keys_must_be_strings(self):
        for key in self.REPO_STRING_KEYS:
            with tempfile.TemporaryDirectory() as tmp:
                repo = minimal_repo("ios", tmp)
                repo[key] = ["x"]
                problems = config.validate(config.load(write_json(tmp, {"repos": [repo]})))
            self.assertIn("repos[ios].%s must be a string" % key, problems)

    def test_stuck_minutes_must_map_known_steps_to_positive_integers(self):
        for value in ({"implement": 0}, {"nope": 10}, [], {"implement": True}, {"implement": "5"}):
            problems = self.problems_for({"repos": [], "stuck_minutes": value})
            self.assertTrue(any(p.startswith("stuck_minutes") for p in problems), (value, problems))
        self.assertEqual(self.problems_for({"repos": [], "stuck_minutes": {"implement": 200}}), [])

    def test_ci_review_prompt_must_exist_under_repo(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = minimal_repo("ios", tmp)
            repo["ci_review_prompt"] = "docs/review.md"
            cfg = config.load(write_json(tmp, {"repos": [repo]}))
            problems = config.validate(cfg)
            self.assertTrue(
                any("repos[ios].ci_review_prompt does not exist" in p for p in problems),
                problems,
            )
            (Path(tmp) / "docs").mkdir()
            (Path(tmp) / "docs" / "review.md").write_text("x")
            self.assertEqual(config.validate(cfg), [])

    def test_jira_auth_must_be_mcp_or_api_token(self):
        jira = {"site": "https://example.atlassian.net", "email": "a@example.com", "keychain_service": "s"}
        for value in ("mcp", "api_token"):
            self.assertEqual(self.problems_for({"repos": [], "jira": dict(jira, auth=value)}), [])
        self.assertEqual(self.problems_for({"repos": [], "jira": jira}), [])
        for value in ("oauth", 1, None):
            problems = self.problems_for({"repos": [], "jira": dict(jira, auth=value)})
            self.assertIn("jira.auth must be 'mcp' or 'api_token'", problems)

    def test_example_config_documents_optional_keys(self):
        data = json.loads((ROOT / "config.example.json").read_text())
        for key in self.STRING_KEYS:
            self.assertIn(key, data)
        repo_keys = set()
        for repo in data["repos"]:
            repo_keys.update(repo)
        for key in self.REPO_STRING_KEYS:
            self.assertIn(key, repo_keys)


class CliTests(unittest.TestCase):
    def run_config_check(self, config_file):
        out = io.StringIO()
        with mock.patch.dict(os.environ, {"TICKET_PILOT_CONFIG": str(config_file)}):
            with redirect_stdout(out):
                code = cli.main(["config-check"])
        return code, out.getvalue()

    def test_cli_exit_code_2_on_problems(self):
        with tempfile.TemporaryDirectory() as tmp:
            code, output = self.run_config_check(Path(tmp) / "absent.json")
        self.assertEqual(code, 2)
        self.assertIn("config file not found", output)

    def test_cli_ok(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = write_json(tmp, {"repos": [minimal_repo("ios", tmp)]})
            code, output = self.run_config_check(path)
        self.assertEqual(code, 0)
        self.assertEqual(output.strip(), "OK")


if __name__ == "__main__":
    unittest.main()
