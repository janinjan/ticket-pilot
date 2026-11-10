"""ticket-pilot command line entry point.

To add a subcommand: write a `cmd_<name>(args) -> int` function and register
it in `build_parser` with `subparsers.add_parser(...)` and `set_defaults(func=...)`.
"""
from __future__ import annotations

import argparse
import sys

from ticket_pilot import config


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


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="tp")
    subparsers = parser.add_subparsers(dest="command", required=True)

    check = subparsers.add_parser("config-check", help="validate the local config")
    check.set_defaults(func=cmd_config_check)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
