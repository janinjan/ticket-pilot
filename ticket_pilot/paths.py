"""Filesystem locations used by ticket-pilot."""
import os
from pathlib import Path


def state_home() -> Path:
    override = os.environ.get("TICKET_PILOT_HOME")
    if override:
        return Path(override)
    return Path.home() / "Library" / "Application Support" / "ticket-pilot"


def runs_dir() -> Path:
    path = state_home() / "runs"
    path.mkdir(parents=True, exist_ok=True)
    return path


def config_path() -> Path:
    override = os.environ.get("TICKET_PILOT_CONFIG")
    if override:
        return Path(override)
    return Path.home() / ".config" / "ticket-pilot" / "config.json"
