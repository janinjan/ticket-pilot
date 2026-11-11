"""Claude Code session hooks: keep each run's session state in sync."""
from __future__ import annotations

import json
import os
import re
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

from ticket_pilot import paths, runs

START_PROMPT = re.compile(r"^/ticket-pilot:start\s+(%s)(?!\S)" % runs.KEY_PATTERN)
SAFE_SESSION_ID = re.compile(r"^[A-Za-z0-9_-][A-Za-z0-9._-]*$")
PENDING_MAX_AGE = timedelta(hours=24)


def _sessions_dir() -> Path:
    path = paths.state_home() / "sessions"
    path.mkdir(parents=True, exist_ok=True)
    return path


def _pending_path(session_id: str) -> Path:
    return paths.state_home() / "sessions" / ("%s.json" % session_id)


def _load_pending(session_id: str) -> dict | None:
    try:
        with open(str(_pending_path(session_id)), encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or not isinstance(data.get("key"), str) or _is_stale(data):
        _delete_pending(session_id)
        return None
    return data


def _is_stale(record: dict) -> bool:
    try:
        created = datetime.strptime(record.get("created_at"), "%Y-%m-%dT%H:%M:%SZ")
    except (TypeError, ValueError):
        return True
    return datetime.now(timezone.utc) - created.replace(tzinfo=timezone.utc) > PENDING_MAX_AGE


def _save_pending(session_id: str, key: str, cwd: str) -> None:
    record = {"session_id": session_id, "key": key, "cwd": cwd, "created_at": runs.now()}
    directory = _sessions_dir()
    descriptor, temp_name = tempfile.mkstemp(dir=str(directory), suffix=".tmp")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(record, handle, indent=2)
        os.replace(temp_name, str(_pending_path(session_id)))
    except BaseException:
        if os.path.exists(temp_name):
            os.unlink(temp_name)
        raise


def _delete_pending(session_id: str) -> None:
    try:
        os.unlink(str(_pending_path(session_id)))
    except OSError:
        pass


def _contains(root, cwd: Path) -> bool:
    if not isinstance(root, str) or not root:
        return False
    resolved = Path(root).resolve()
    return cwd == resolved or resolved in cwd.parents


def _find_run(key: str, cwd: str) -> dict | None:
    resolved_cwd = Path(cwd).resolve()
    for run in runs.existing_runs():
        if run.get("key") != key:
            continue
        if _contains(run.get("repo_path"), resolved_cwd) or _contains(run.get("worktree"), resolved_cwd):
            return run
    return None


def _bind(key: str, session_id: str, cwd: str) -> dict | None:
    run = _find_run(key, cwd)
    if run is None:
        return None
    run = runs.bind_session(run["id"], session_id)
    run["session"] = {"state": "running", "last_notification": None, "notified_at": None}
    runs.save(run)
    _delete_pending(session_id)
    return run


def _start_key(event_name: str, prompt) -> str | None:
    if event_name != "UserPromptSubmit" or not isinstance(prompt, str):
        return None
    match = START_PROMPT.match(prompt)
    return match.group(1) if match else None


def _resolve(event_name: str, prompt, session_id: str, cwd: str) -> dict | None:
    run = runs.find_by_session(session_id)
    key = _start_key(event_name, prompt)
    if key is not None:
        if run is not None and run.get("key") == key:
            return run
        if run is not None:
            runs.update(run["id"], session_id=None)
        run = _bind(key, session_id, cwd)
        if run is None:
            _save_pending(session_id, key, cwd)
        return run
    if run is not None:
        return run
    pending = _load_pending(session_id)
    if pending is None:
        return None
    return _bind(pending["key"], session_id, cwd)


def _session(run: dict) -> dict:
    session = run.get("session")
    if not isinstance(session, dict):
        session = {"state": "running", "last_notification": None, "notified_at": None}
        run["session"] = session
    return session


def _apply(event: dict, run: dict) -> None:
    name = event["hook_event_name"]
    session = _session(run)
    if name == "UserPromptSubmit":
        session["state"] = "running"
        if run.get("status") != "done":
            run["status"] = "running"
            run["waiting"] = None
    elif name == "Stop":
        session["state"] = "waiting"
        if run.get("status") != "done" and not run.get("waiting"):
            run["status"] = "waiting"
            run["waiting"] = {"kind": runs.INPUT_KIND, "text": "", "since": runs.now()}
    elif name == "Notification":
        message = event.get("message")
        session["last_notification"] = message if isinstance(message, str) else None
        session["notified_at"] = runs.now()
    elif name == "SessionStart":
        session["state"] = "running"
    else:
        return
    runs.save(run)


def handle(event: dict) -> None:
    if not isinstance(event, dict):
        return
    session_id = event.get("session_id")
    cwd = event.get("cwd")
    name = event.get("hook_event_name")
    if not isinstance(session_id, str) or not SAFE_SESSION_ID.match(session_id):
        return
    if not isinstance(cwd, str) or not cwd or not isinstance(name, str):
        return
    if name not in ("UserPromptSubmit", "Stop", "Notification", "SessionStart"):
        return
    run = _resolve(name, event.get("prompt"), session_id, cwd)
    if run is not None:
        _apply(event, run)
