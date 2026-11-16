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
    session["cwd"] = event["cwd"]
    if name == "UserPromptSubmit":
        session["state"] = "running"
        session.pop("ended_at", None)
        if run.get("status") != "done":
            run["status"] = "running"
            run["waiting"] = None
    elif name == "Stop" and _has_background_work(event.get("transcript_path")):
        # The turn ends on agents, a build or a monitor still running: Claude resumes by itself when they
        # finish, so the run is not waiting for the user. An earlier plain end of turn is no longer true.
        session["state"] = "running"
        if run.get("status") != "done" and _is_plain_wait(run):
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
        session.pop("ended_at", None)
    elif name == "SessionEnd":
        session["state"] = "ended"
        session["ended_at"] = runs.now()
    else:
        return
    runs.save(run)


def _is_plain_wait(run: dict) -> bool:
    waiting = run.get("waiting")
    return isinstance(waiting, dict) and waiting.get("kind") == runs.INPUT_KIND


# What a tool answers when it starts work in the background (an agent, a command, a monitor); the work
# then ends with a task notification that names the tool call.
BACKGROUND_STARTED = re.compile(
    r"^\s*(Async agent launched|Command running in background|Monitor started|Workflow started)", re.I
)
TASK_ENDED = re.compile(
    r"<task-notification>.*?<tool-use-id>([^<\s]+)</tool-use-id>.*?<status>(\w+)</status>", re.S
)
# Background work started longer ago than this no longer holds the run back, should its notification
# never come.
BACKGROUND_MAX_AGE = timedelta(hours=2)


def _texts(value):
    """Every string inside a decoded JSON value."""
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for item in value:
            yield from _texts(item)
    elif isinstance(value, dict):
        for item in value.values():
            yield from _texts(item)


def _result_text(content) -> str:
    """A tool result's text: a string, or the first text block of a list."""
    if isinstance(content, str):
        return content
    for block in content if isinstance(content, list) else []:
        if isinstance(block, dict) and isinstance(block.get("text"), str):
            return block["text"]
    return ""


def _timestamp(value) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        # Python 3.9 reads neither the "Z" nor milliseconds of other than 3 or 6 digits.
        return datetime.strptime(value[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def _has_background_work(transcript_path) -> bool:
    """The session's transcript has background work started and not ended yet. Any doubt (no transcript,
    unreadable) reads as none: the run then waits for the user, as before."""
    if not isinstance(transcript_path, str) or not transcript_path:
        return False
    started: dict[str, datetime | None] = {}
    ended: set[str] = set()
    try:
        with open(transcript_path, encoding="utf-8") as handle:
            for line in handle:
                if "tool_result" not in line and "<task-notification>" not in line:
                    continue
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(entry, dict) or entry.get("type") == "assistant":
                    continue
                message = entry.get("message")
                content = message.get("content") if isinstance(message, dict) else None
                for block in content if isinstance(content, list) else []:
                    if not isinstance(block, dict) or block.get("type") != "tool_result":
                        continue
                    if BACKGROUND_STARTED.match(_result_text(block.get("content"))) and isinstance(block.get("tool_use_id"), str):
                        started[block["tool_use_id"]] = _timestamp(entry.get("timestamp"))
                for text in _texts(entry):
                    for match in TASK_ENDED.finditer(text):
                        if match.group(2).lower() != "running":
                            ended.add(match.group(1))
    except OSError:
        return False
    cutoff = datetime.now(timezone.utc) - BACKGROUND_MAX_AGE
    return any(
        tool_id not in ended and (at is None or at >= cutoff) for tool_id, at in started.items()
    )


AUTONOMY_REMINDER = (
    "ticket-pilot: before asking the user anything, look for the answer yourself "
    "(the app you drive, the repo, the config, the tools such as the proxy CLI and the simulator; "
    "retry tooling failures with tp run-shell or the repo's build skill). "
    "Ask only for a decision that is the user's, an action visible to others, "
    "or what you genuinely cannot obtain \u2014 and say what you tried."
)


def _reminder(run: dict) -> str | None:
    if run.get("status") == "done":
        return None
    parts = []
    language = run.get("language")
    if isinstance(language, str) and language.strip():
        parts.append(
            "ticket-pilot: write every message to the user in the run's language (%s), "
            "including one-line progress notes between tool calls and summaries after tool or agent output; "
            "a one-word reply such as \"go\" or \"ok\" does not change the language; translate tool output, "
            "never paste it in another language." % language.strip()
        )
    parts.append(AUTONOMY_REMINDER)
    return json.dumps({"hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": " ".join(parts),
    }})


def handle(event: dict) -> str | None:
    """Apply a hook event. Returns the JSON to print on stdout, or None to stay silent."""
    if not isinstance(event, dict):
        return None
    session_id = event.get("session_id")
    cwd = event.get("cwd")
    name = event.get("hook_event_name")
    if not isinstance(session_id, str) or not SAFE_SESSION_ID.match(session_id):
        return None
    if not isinstance(cwd, str) or not cwd or not isinstance(name, str):
        return None
    if name not in ("UserPromptSubmit", "Stop", "Notification", "SessionStart", "SessionEnd"):
        return None
    if name == "SessionEnd":
        # Only a run already bound to this session; never bind a new one here.
        run = runs.find_by_session(session_id)
        if run is not None:
            _apply(event, run)
        return None
    run = _resolve(name, event.get("prompt"), session_id, cwd)
    if run is None:
        return None
    _apply(event, run)
    return _reminder(run) if name == "UserPromptSubmit" else None
