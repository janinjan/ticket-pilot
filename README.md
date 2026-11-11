# ticket-pilot

A Claude Code plugin that turns an assigned Jira ticket into verified, review-ready commits.

You give it a ticket key. It reads everything linked to the ticket, waits for your go, then works in a dedicated git worktree and stops at local commits, a test plan and a report. It never sends anything to anyone on its own.

## What it does

Running `/ticket-pilot:start <KEY>` walks through 10 mandatory steps:

1. Understand: read the ticket, every comment and every linked source, then list the numbered requests and wait for your go.
2. Prepare: sync the repo, create a dedicated worktree and branch, and run the repo setup.
3. Research: explore in parallel the twin tickets, the other platforms, the backend contract, precedents and the module architecture.
4. Compare and decide: build a comparison table, ask one question per real divergence, and settle the target behaviour.
5. Implement: write the change behind a feature toggle, with tests, following the repo conventions.
6. Verify: build, run the tests, check snapshots, test necessity, and that the toggle OFF behaviour is unchanged.
7. Test in the app: launch the app and drive it, then write a QA-format test plan with results.
8. Review and audit: run a reviewer agent (score from -2 to +2) and an auditor agent with a fresh context, then fix what is confirmed.
9. Commits: create Conventional Commits, split by size when over the threshold, and verify every commit one by one.
10. Report: summarize requests, alignment, proofs, test plan and results, and print the command that sends the branch.

Progress is tracked per run in the ticket-pilot state directory, so a stopped run can be resumed.

The plugin also ships a read-only `reviewer` agent, a read-only `auditor` agent, hooks that track which Claude Code session belongs to which run, and the `tp` command line tool.

A menu bar app that shows the runs and the questions waiting for you is a separate, later component. It is not part of this plugin.

## Install

Requirements:

- macOS
- `/usr/bin/python3` (installed with the Command Line Tools: `xcode-select --install`); only the standard library is used
- git
- The Atlassian and Figma MCP servers are recommended for step 1 (reading tickets, Confluence pages and designs). Without them the skill lists those sources as unread.

From a marketplace (replace `<owner>` with the GitHub owner hosting this repository):

```sh
claude plugin marketplace add <owner>/ticket-pilot
claude plugin install ticket-pilot@ticket-pilot
```

For local development, point Claude Code at a checkout:

```sh
claude --plugin-dir /path/to/ticket-pilot
```

## Configure

After `claude plugin install`, the plugin lives in Claude Code's cache, not in a checkout you control:

```
~/.claude/plugins/cache/ticket-pilot/ticket-pilot/<version>/
```

Find the latest one and keep it in a variable (in a local-development setup, use your checkout instead, for example `TP_ROOT=/path/to/ticket-pilot`, the same path as `--plugin-dir`):

```sh
TP_ROOT=$(ls -d ~/.claude/plugins/cache/ticket-pilot/ticket-pilot/*/ | tail -1)
```

Optionally, add a shell alias so that `tp` works from anywhere (put it in your shell profile with the `TP_ROOT` line):

```sh
alias tp="$TP_ROOT/bin/tp"
```

The path changes with each plugin version, so run the `TP_ROOT` line again after an update.

1. Copy the example config:

   ```sh
   mkdir -p ~/.config/ticket-pilot
   cp "$TP_ROOT/config.example.json" ~/.config/ticket-pilot/config.json
   ```

   Set `TICKET_PILOT_CONFIG` to use another location, and `TICKET_PILOT_HOME` to move the state directory.

2. Edit it: your Jira site, one entry per repository, and the backend paths.
3. Store your Jira API token in the macOS Keychain under the service named by `jira.keychain_service` (it is only used when the Atlassian MCP server is not available):

   ```sh
   security add-generic-password -a "$USER" -s "ticket-pilot-jira" -w "<token>"
   ```

4. Validate it:

   ```sh
   "$TP_ROOT/bin/tp" config-check
   ```

   It prints `OK`, or one line per problem (exit code 2).

## Configuration reference

Paths accept `~`. Keys marked optional can be omitted.

| Key | Required | Meaning | Default |
|---|---|---|---|
| `jira.site` | yes | Base URL of your Jira site | none |
| `jira.email` | yes | Account email used for the REST fallback | none |
| `jira.keychain_service` | yes | Keychain service holding the Jira API token | none |
| `repos` | yes | List of repositories the plugin may work in | none |
| `repos[].name` | yes | Unique short name, used in run ids (`KEY--name`) | none |
| `repos[].path` | yes | Main checkout of the repository (must exist) | none |
| `repos[].main_branch` | yes | Branch worktrees are created from (`origin/<main_branch>`) | none |
| `repos[].review` | yes | `gerrit` or `github`: decides the command printed to send the branch | none |
| `repos[].match` | no | `title_prefixes`, `labels`, `components`: how twin tickets of this platform are recognised | none |
| `repos[].setup_command` | no | Command run in a new worktree and after each checkout of step 9 (project generation, generated code, dependencies) | repo's own build skill |
| `repos[].sync_command` | no | Overrides the top-level `sync_command` for this repo | top-level, else `git fetch origin` |
| `repos[].launch_skill` | no | Skill used to build and launch the app in step 7 | repo's own launch skill |
| `repos[].ci_review_prompt` | no | Path relative to the repo of the prompt your CI review bot uses; passed to the reviewer (must exist) | none |
| `backend.repos` | no | Backend checkouts read in step 3 | `[]` |
| `backend.api_docs` | no | API documentation paths read in step 3 | `[]` |
| `sync_command` | no | Command that syncs a repo before a worktree is created | `git fetch origin` |
| `reviewer_agent` | no | Agent type used as reviewer | `ticket-pilot:reviewer` |
| `auditor_agent` | no | Agent type used as auditor | `ticket-pilot:auditor` |
| `terminal_app` | no | Terminal application used by the future menu bar app to open sessions | none |
| `permission_mode` | no | Claude Code permission mode used by the future menu bar app to start sessions | none |
| `max_commit_lines` | no | Review size threshold: added plus removed lines per commit | `999` |
| `generated_globs` | no | Files excluded from the commit size count | `[]` |
| `snapshot_globs` | no | Snapshot files excluded from the commit size count | `["**/__Snapshots__/**"]` |
| `poll_minutes` | no | Polling interval in minutes, for the future menu bar app | `5` |
| `ready_statuses` | no | Jira statuses meaning a ticket is ready to start, for the future menu bar app | `["To Start"]` |

## Usage

From inside one of the configured repositories, in Claude Code:

```
/ticket-pilot:start <KEY>
```

The skill reads the ticket, shows the numbered requests and asks for your go. Questions come one at a time, each with a recommendation. At the end you get a report and the command to send the branch; running it is up to you.

Useful `tp` commands (`TP_ROOT` is defined in Configure; with the alias, just `tp ...`):

```sh
"$TP_ROOT/bin/tp" run-list                 # every run: id, status, step, worktree
"$TP_ROOT/bin/tp" run-show <KEY>--<repo>   # state of a run
"$TP_ROOT/bin/tp" commit-size --staged     # size of the staged change against the threshold
```

If a run was stopped, starting the same ticket again offers to resume it at the step where it stopped.

## Safety

**Nothing visible to others without an explicit yes.** Without an explicit yes from you, for that exact action, in that session, the plugin never pushes, opens a pull request or review, posts a comment, votes, transitions or comments on a Jira ticket, sends a message, or does anything else another person can see or that changes a shared system. A yes for one action never covers another. It stops at local commits and prints the command that sends them.

Other guarantees:

- The work happens in a dedicated worktree; your main checkout is never edited.
- New behaviour goes behind a feature toggle, and the toggle OFF behaviour must be proven unchanged.
- Every claim in the report comes with its proof, or is marked as unproven.
- The reviewer reduces the comments your CI review bot will make, but it does not guarantee zero CI bot comments.

## Tests

```sh
python3 -m unittest discover -s tests -v
```

## License

See `LICENSE`.
