"""ticket-pilot command line entry point.

To add a subcommand: write a `cmd_<name>(args) -> int` function and register
it in `build_parser` with `subparsers.add_parser(...)` and `set_defaults(func=...)`.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

from ticket_pilot import commit_size, config, hooks, runs


def cmd_config_check(args: argparse.Namespace) -> int:
    try:
        cfg = config.load()
        problems = config.validate(cfg)
    except (OSError, ValueError) as error:
        problems = ["config file is not readable JSON: %s" % error]
    if problems:
        for problem in problems:
            print(problem)
        return 2
    print("OK")
    return 0


def _fail(message: str) -> int:
    print(message, file=sys.stderr)
    return 2


def _with_run(args: argparse.Namespace, action) -> int:
    try:
        action()
    except KeyError:
        return _fail("unknown run: %s" % args.run_id)
    except ValueError as error:
        return _fail(str(error))
    return 0


def cmd_run_start(args: argparse.Namespace) -> int:
    try:
        run = runs.start(args.key, args.repo, args.repo_path)
    except ValueError as error:
        return _fail(str(error))
    print(run["id"])
    return 0


def cmd_run_step(args: argparse.Namespace) -> int:
    if not 1 <= args.step <= len(runs.STEP_NAMES):
        return _fail("step must be between 1 and %d" % len(runs.STEP_NAMES))
    name = runs.STEP_NAMES[args.step - 1]
    return _with_run(args, lambda: runs.set_step(args.run_id, args.step, name))


def cmd_run_wait(args: argparse.Namespace) -> int:
    return _with_run(args, lambda: runs.set_waiting(args.run_id, args.kind, args.text))


def cmd_run_done(args: argparse.Namespace) -> int:
    return _with_run(args, lambda: runs.set_done(args.run_id))


def cmd_run_report(args: argparse.Namespace) -> int:
    if runs.load(args.run_id) is None:
        return _fail("unknown run: %s" % args.run_id)
    code = _with_run(args, lambda: runs.save_report(args.run_id, sys.stdin.read()))
    if code == 0:
        print(runs.report_path(args.run_id))
    return code


def cmd_run_show(args: argparse.Namespace) -> int:
    run = runs.load(args.run_id)
    if run is None:
        return _fail("unknown run: %s" % args.run_id)
    print(json.dumps(run, indent=2))
    return 0


def _run_environment(run: dict) -> dict | None:
    """The repo entry's `env` for a run, placeholders substituted; None when the config is unreadable."""
    try:
        cfg = config.load()
    except (OSError, ValueError) as error:
        _fail("config file is not readable JSON: %s" % error)
        return None
    repo = config.repo_by_name(cfg, run.get("repo", ""))
    env = repo.get("env") if repo else None
    result = {}
    if not isinstance(env, dict):
        return result
    worktree = run.get("worktree")
    for name, value in env.items():
        if not isinstance(value, str) or not re.fullmatch(config.ENV_NAME_PATTERN, str(name)):
            continue
        if "{worktree}" in value and not worktree:
            print("%s skipped: the worktree is not recorded yet" % name, file=sys.stderr)
            continue
        value = value.replace("{repo}", run.get("repo_path") or "")
        result[str(name)] = value.replace("{worktree}", worktree or "")
    return result


def cmd_run_env(args: argparse.Namespace) -> int:
    run = runs.load(args.run_id)
    if run is None:
        return _fail("unknown run: %s" % args.run_id)
    env = _run_environment(run)
    if env is None:
        return 2
    for name, value in env.items():
        print("export %s='%s'" % (name, value.replace("'", "'\\''")))
    return 0


def cmd_run_shell(args: argparse.Namespace) -> int:
    run = runs.load(args.run_id)
    if run is None:
        return _fail("unknown run: %s" % args.run_id)
    worktree = run.get("worktree")
    if not worktree:
        return _fail("the worktree of %s is not recorded yet (tp run-set %s --worktree)" % (args.run_id, args.run_id))
    env = _run_environment(run)
    if env is None:
        return 2
    shell = os.environ.get("SHELL") or "/bin/zsh"
    try:
        return subprocess.call(
            [shell, "-l", "-i", "-c", args.command],
            cwd=worktree,
            env=dict(os.environ, **env),
            stdin=subprocess.DEVNULL,
        )
    except OSError as error:
        return _fail("cannot run %s in %s: %s" % (shell, worktree, error))


def cmd_run_list(args: argparse.Namespace) -> int:
    for run in runs.existing_runs():
        print("%s %s step %d %s %s" % (
            run["id"], run["status"], run["step"], run["step_name"], run.get("worktree") or "-",
        ))
    return 0


def cmd_run_set(args: argparse.Namespace) -> int:
    fields = {}
    if args.worktree is not None:
        fields["worktree"] = args.worktree
    if args.branch is not None:
        fields["branch"] = args.branch
    if args.jira_line is not None:
        fields["jira_line"] = args.jira_line == "yes"
    if args.request is not None:
        fields["requests"] = args.request
    if args.title is not None:
        fields["title"] = args.title
    if args.language is not None:
        if not re.fullmatch(runs.LANGUAGE_PATTERN, args.language):
            return _fail("invalid language: %r (expected %s, for example fr or en-GB)" % (args.language, runs.LANGUAGE_PATTERN))
        fields["language"] = args.language
    if not fields:
        return _fail("run-set needs at least one of --worktree, --branch, --jira-line, --request, --title, --language")
    return _with_run(args, lambda: runs.update(args.run_id, **fields))


def cmd_hook(args: argparse.Namespace) -> int:
    # A hook must never disturb the Claude Code session: exit 0, and the only
    # possible output is the language reminder JSON of a UserPromptSubmit.
    try:
        output = hooks.handle(json.loads(sys.stdin.read()))
        if isinstance(output, str) and output:
            sys.stdout.write(output + "\n")
    except Exception:
        pass
    return 0


def cmd_commit_size(args: argparse.Namespace) -> int:
    try:
        cfg = config.load()
    except (OSError, ValueError) as error:
        return _fail("config file is not readable JSON: %s" % error)
    globs = list(cfg.get("generated_globs") or []) + list(cfg.get("snapshot_globs") or [])
    try:
        text = commit_size.numstat(args.rev, args.staged)
    except (OSError, ValueError) as error:
        return _fail("cannot measure commit size: %s" % error)
    lines = commit_size.parse_numstat(text, globs)
    verdict = "over" if lines > cfg["max_commit_lines"] else "ok"
    print("%d %s %s" % (lines, commit_size.size_class(lines), verdict))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="tp")
    subparsers = parser.add_subparsers(dest="command", required=True)

    check = subparsers.add_parser("config-check", help="validate the local config")
    check.set_defaults(func=cmd_config_check)

    start = subparsers.add_parser("run-start", help="create a run (idempotent)")
    start.add_argument("key")
    start.add_argument("repo")
    start.add_argument("repo_path")
    start.set_defaults(func=cmd_run_start)

    step = subparsers.add_parser("run-step", help="move a run to step N")
    step.add_argument("run_id")
    step.add_argument("step", type=int)
    step.set_defaults(func=cmd_run_step)

    wait = subparsers.add_parser("run-wait", help="mark a run as waiting for the user")
    wait.add_argument("run_id")
    wait.add_argument("kind", help="one of: " + ", ".join(runs.WAIT_KINDS))
    wait.add_argument("text")
    wait.set_defaults(func=cmd_run_wait)

    done = subparsers.add_parser("run-done", help="mark a run as done")
    done.add_argument("run_id")
    done.set_defaults(func=cmd_run_done)

    report = subparsers.add_parser("run-report", help="save the run's final report, read from stdin")
    report.add_argument("run_id")
    report.set_defaults(func=cmd_run_report)

    show = subparsers.add_parser("run-show", help="print a run as JSON")
    show.add_argument("run_id")
    show.set_defaults(func=cmd_run_show)

    env = subparsers.add_parser("run-env", help="print the repo's environment as export lines")
    env.add_argument("run_id")
    env.set_defaults(func=cmd_run_env)

    shell = subparsers.add_parser(
        "run-shell",
        help="run one command string in the run's worktree, with the run's env, in the user's login shell",
    )
    shell.add_argument("run_id")
    shell.add_argument("command", help="the whole command, as ONE quoted string")
    shell.set_defaults(func=cmd_run_shell)

    listing = subparsers.add_parser("run-list", help="print one line per stored run")
    listing.set_defaults(func=cmd_run_list)

    update = subparsers.add_parser("run-set", help="set worktree, branch, jira-line, requests or title")
    update.add_argument("run_id")
    update.add_argument("--worktree")
    update.add_argument("--branch")
    update.add_argument("--jira-line", choices=["yes", "no"])
    update.add_argument(
        "--request", action="append",
        help="one numbered request, in order; repeat it for each one (replaces the stored list)",
    )
    update.add_argument("--title", help="the ticket's title, shown by the menu bar app")
    update.add_argument("--language", help="the language decided for the user, such as fr or en")
    update.set_defaults(func=cmd_run_set)

    size = subparsers.add_parser("commit-size", help="measure a commit against the review threshold")
    size.add_argument("rev", nargs="?", default="HEAD")
    size.add_argument("--staged", action="store_true", help="measure the staged changes")
    size.set_defaults(func=cmd_commit_size)

    hook = subparsers.add_parser("hook", help="handle a Claude Code hook event from stdin")
    hook.add_argument("ignored", nargs="*", help=argparse.SUPPRESS)
    hook.set_defaults(func=cmd_hook)

    return parser


def main(argv: list[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv[1:]
    if argv[:1] == ["hook"]:
        # Hooks must stay silent and exit 0 whatever arguments they receive.
        return cmd_hook(argparse.Namespace())
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
