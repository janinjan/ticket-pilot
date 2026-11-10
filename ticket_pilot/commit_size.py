"""Commit size measurement against the review threshold."""
from __future__ import annotations

import re
import subprocess

_BRACE_RENAME = re.compile(r"\{([^{}]*) => ([^{}]*)\}")


def destination_path(path: str) -> str:
    """Return the destination of a numstat path, resolving rename notations."""
    if _BRACE_RENAME.search(path):
        resolved = _BRACE_RENAME.sub(lambda match: match.group(2), path)
        return re.sub(r"/{2,}", "/", resolved)
    if " => " in path:
        return path.split(" => ", 1)[1]
    return path


def _glob_to_regex(glob: str) -> "re.Pattern[str]":
    parts: list[str] = []
    index = 0
    while index < len(glob):
        if glob.startswith("**/", index):
            parts.append("(?:.*/)?")
            index += 3
        elif glob.startswith("/**", index) and index + 3 == len(glob):
            parts.append("(?:/.*)?")
            index += 3
        elif glob.startswith("**", index):
            parts.append(".*")
            index += 2
        elif glob[index] == "*":
            parts.append("[^/]*")
            index += 1
        elif glob[index] == "?":
            parts.append("[^/]")
            index += 1
        else:
            parts.append(re.escape(glob[index]))
            index += 1
    return re.compile("".join(parts) + r"\Z")


def matches_glob(path: str, glob: str) -> bool:
    """`**` spans any number of segments (or none); `*` stays within one segment."""
    return _glob_to_regex(glob).match(path) is not None


def parse_numstat(text: str, excluded_globs: list[str]) -> int:
    """Sum added and deleted lines, skipping binary files and excluded paths."""
    total = 0
    for line in text.splitlines():
        fields = line.split("\t", 2)
        if len(fields) != 3:
            continue
        added, deleted, raw_path = fields
        path = destination_path(raw_path)
        if any(matches_glob(path, glob) for glob in excluded_globs):
            continue
        if added == "-" or deleted == "-":
            continue
        try:
            total += int(added) + int(deleted)
        except ValueError:
            continue
    return total


def size_class(lines: int) -> str:
    if lines < 10:
        return "XS"
    if lines < 50:
        return "S"
    if lines < 250:
        return "M"
    if lines < 1000:
        return "L"
    return "XL"


def _git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", "-c", "core.quotePath=false", *args],
        capture_output=True, text=True, encoding="utf-8", errors="replace",
    )


def numstat(rev: str | None, staged: bool) -> str:
    """Return `git` numstat output for a commit or the index. Raises ValueError."""
    if staged:
        result = _git("diff", "--cached", "-M", "--numstat")
    else:
        rev = rev or "HEAD"
        has_parent = _git("rev-parse", "--verify", "--quiet", rev + "^")
        if has_parent.returncode == 0:
            result = _git("diff", "-M", "--numstat", rev + "^!")
        else:
            result = _git("show", "-M", "--numstat", "--format=", rev)
    if result.returncode != 0:
        raise ValueError(result.stderr.strip() or "git failed")
    return result.stdout
