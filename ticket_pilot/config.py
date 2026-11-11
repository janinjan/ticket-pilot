"""Local configuration loading and validation."""
from __future__ import annotations

import copy
import json
import re
from pathlib import Path

from ticket_pilot import paths, runs

DEFAULTS = {
    "max_commit_lines": 999,
    "poll_minutes": 5,
    "ready_statuses": ["To Start"],
    "generated_globs": [],
    "snapshot_globs": ["**/__Snapshots__/**"],
}

REVIEW_KINDS = ("gerrit", "github")

JIRA_AUTH_KINDS = ("mcp", "api_token")

REPO_STRING_KEYS = (
    "setup_command", "ci_review_prompt", "ci_review_command", "launch_skill", "sync_command", "editor",
)
TOP_STRING_KEYS = (
    "sync_command",
    "reviewer_agent",
    "auditor_agent",
    "terminal_app",
    "permission_mode",
    "git_client",
)


def load(path: Path | None = None) -> dict:
    """Read the config file and apply defaults.

    A missing file does not raise: defaults are returned with `_missing=True`
    and `_path` set so that `validate` can report it.
    """
    config_file = Path(path) if path is not None else paths.config_path()
    cfg = copy.deepcopy(DEFAULTS)
    cfg["_path"] = str(config_file)
    if not config_file.is_file():
        cfg["_missing"] = True
        return cfg
    with config_file.open() as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        cfg["_invalid"] = "config must be a JSON object, got %s" % type(data).__name__
        return cfg
    cfg.update(data)
    return cfg


def validate(cfg: dict) -> list[str]:
    """Return human-readable problems (empty list means the config is OK)."""
    if cfg.get("_missing"):
        return ["config file not found: %s" % cfg.get("_path", "")]

    if cfg.get("_invalid"):
        return [cfg["_invalid"]]

    problems: list[str] = []
    repos = cfg.get("repos")
    if not isinstance(repos, list):
        problems.append("repos must be a list")
        repos = []
    seen = set()
    for index, repo in enumerate(repos):
        if not isinstance(repo, dict):
            problems.append("repos[%d] must be an object" % index)
            continue
        name = repo.get("name")
        if not isinstance(name, str) or not name:
            problems.append("repos[%d].name must be a non-empty string" % index)
            continue
        if not re.fullmatch(runs.REPO_PATTERN, name):
            problems.append("repos[%d].name must match ^%s$" % (index, runs.REPO_PATTERN))
            continue
        if name in seen:
            problems.append("repos[%s].name is duplicated" % name)
        seen.add(name)
        if repo.get("review") not in REVIEW_KINDS:
            problems.append("repos[%s].review must be 'gerrit' or 'github'" % name)
        if not repo.get("main_branch"):
            problems.append("repos[%s].main_branch is required" % name)
        repo_path = repo.get("path")
        if not repo_path:
            problems.append("repos[%s].path is required" % name)
        elif not isinstance(repo_path, str):
            problems.append("repos[%s].path must be a string" % name)
        elif not Path(repo_path).expanduser().is_dir():
            problems.append("repos[%s].path does not exist: %s" % (name, repo_path))
        for key in REPO_STRING_KEYS:
            if key in repo and not isinstance(repo[key], str):
                problems.append("repos[%s].%s must be a string" % (name, key))
        prompt = repo.get("ci_review_prompt")
        if (
            isinstance(prompt, str)
            and prompt
            and isinstance(repo_path, str)
            and Path(repo_path).expanduser().is_dir()
            and not (Path(repo_path).expanduser() / prompt).is_file()
        ):
            problems.append(
                "repos[%s].ci_review_prompt does not exist: %s" % (name, prompt)
            )

    jira = cfg.get("jira")
    if isinstance(jira, dict) and "auth" in jira and jira["auth"] not in JIRA_AUTH_KINDS:
        problems.append("jira.auth must be 'mcp' or 'api_token'")

    backend = cfg.get("backend")
    if backend is None:
        backend = {}
    if not isinstance(backend, dict):
        problems.append("backend must be an object")
        backend = {}
    for key in ("repos", "api_docs"):
        entries = backend.get(key, [])
        if not isinstance(entries, list):
            problems.append("backend.%s must be a list" % key)
            continue
        for entry in entries:
            if not isinstance(entry, str):
                problems.append("backend.%s entries must be strings" % key)
            elif not Path(entry).expanduser().exists():
                problems.append("backend.%s path does not exist: %s" % (key, entry))

    for key in TOP_STRING_KEYS:
        if key in cfg and not isinstance(cfg[key], str):
            problems.append("%s must be a string" % key)

    if "stuck_minutes" in cfg:
        stuck = cfg["stuck_minutes"]
        if not isinstance(stuck, dict):
            problems.append("stuck_minutes must be an object of step name to minutes")
        else:
            for step_name, minutes in stuck.items():
                if step_name not in runs.STEP_NAMES:
                    problems.append("stuck_minutes: unknown step %r" % step_name)
                elif isinstance(minutes, bool) or not isinstance(minutes, int) or minutes <= 0:
                    problems.append("stuck_minutes.%s must be a positive integer" % step_name)

    lines = cfg.get("max_commit_lines")
    if isinstance(lines, bool) or not isinstance(lines, int) or lines <= 0:
        problems.append("max_commit_lines must be a positive integer")
    return problems


def repo_by_name(cfg: dict, name: str) -> dict | None:
    repos = cfg.get("repos")
    if not isinstance(repos, list):
        return None
    for repo in repos:
        if isinstance(repo, dict) and repo.get("name") == name:
            return repo
    return None
