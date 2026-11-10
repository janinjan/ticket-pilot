"""Persistent state of ticket runs, one JSON file per run."""
from __future__ import annotations

import json
import os
import re
import tempfile
from datetime import datetime, timezone

from ticket_pilot import paths

STEP_NAMES = [
    "understand",
    "prepare",
    "research",
    "compare",
    "implement",
    "verify",
    "app_test",
    "review",
    "commits",
    "report",
]

WAIT_KINDS = ("go", "question", "launch_app", "report")

KEY_PATTERN = r"[A-Z][A-Z0-9]+-\d+"
REPO_PATTERN = r"[A-Za-z0-9._-]+"


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


_now = now


def validate(key: str, repo: str) -> None:
    """Raise ValueError unless key and repo are safe to name a run file."""
    if not isinstance(key, str) or not re.fullmatch(KEY_PATTERN, key):
        raise ValueError("invalid ticket key: %r (expected %s)" % (key, KEY_PATTERN))
    if not isinstance(repo, str) or not re.fullmatch(REPO_PATTERN, repo):
        raise ValueError("invalid repo name: %r (expected %s)" % (repo, REPO_PATTERN))


def run_id(key: str, repo: str) -> str:
    validate(key, repo)
    return "%s--%s" % (key, repo)


def _path(run_identifier: str):
    return paths.runs_dir() / ("%s.json" % run_identifier)


def load(run_identifier: str) -> dict | None:
    try:
        with open(_path(run_identifier), encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def save(run: dict) -> None:
    run["updated_at"] = _now()
    directory = paths.runs_dir()
    descriptor, temp_name = tempfile.mkstemp(dir=str(directory), suffix=".tmp")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(run, handle, indent=2)
        os.replace(temp_name, str(_path(run["id"])))
    except BaseException:
        if os.path.exists(temp_name):
            os.unlink(temp_name)
        raise


def _require(run_identifier: str) -> dict:
    run = load(run_identifier)
    if run is None:
        raise KeyError(run_identifier)
    return run


def start(key: str, repo: str, repo_path: str) -> dict:
    identifier = run_id(key, repo)
    existing = load(identifier)
    if existing is not None:
        return existing
    now = _now()
    run = {
        "id": identifier,
        "key": key,
        "repo": repo,
        "repo_path": repo_path,
        "worktree": None,
        "branch": None,
        "session_id": None,
        "session": None,
        "step": 1,
        "step_name": STEP_NAMES[0],
        "status": "running",
        "waiting": None,
        "jira_line": None,
        "requests": [],
        "history": [{"step": 1, "started_at": now}],
        "created_at": now,
        "updated_at": now,
    }
    save(run)
    return run


def set_step(run_identifier: str, step: int, name: str) -> dict:
    run = _require(run_identifier)
    now = _now()
    if run["history"] and "ended_at" not in run["history"][-1]:
        run["history"][-1]["ended_at"] = now
    run["history"].append({"step": step, "started_at": now})
    run["step"] = step
    run["step_name"] = name
    run["status"] = "running"
    run["waiting"] = None
    save(run)
    return run


def set_waiting(run_identifier: str, kind: str, text: str) -> dict:
    if kind not in WAIT_KINDS:
        raise ValueError("kind must be one of: %s" % ", ".join(WAIT_KINDS))
    run = _require(run_identifier)
    run["status"] = "waiting"
    run["waiting"] = {"kind": kind, "text": text, "since": _now()}
    save(run)
    return run


def set_done(run_identifier: str) -> dict:
    run = _require(run_identifier)
    run["status"] = "done"
    run["waiting"] = {"kind": "report", "text": "", "since": _now()}
    save(run)
    return run


def update(run_identifier: str, **fields) -> dict:
    run = _require(run_identifier)
    run.update(fields)
    save(run)
    return run


def existing_runs() -> list:
    """All stored runs, without creating the state directory."""
    directory = paths.state_home() / "runs"
    if not directory.is_dir():
        return []
    loaded = (load(path.stem) for path in sorted(directory.glob("*.json")))
    return [run for run in loaded if run is not None]


def find_by_session(session_id: str) -> dict | None:
    for run in existing_runs():
        if run.get("session_id") == session_id:
            return run
    return None


def bind_session(run_identifier: str, session_id: str) -> dict:
    return update(run_identifier, session_id=session_id)
