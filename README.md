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

The plugin also ships a read-only `reviewer` agent, a read-only `auditor` agent, hooks that track which Claude Code session belongs to which run (and when it ends), and the `tp` command line tool.

A macOS menu bar app that shows your runs and the questions waiting for you ships in this repository; see [Menu bar app](#menu-bar-app). Install the app; it offers to install or update the Claude Code plugin it carries.

## Menu bar app

A small macOS app (`app/`, Swift, macOS 14 or later) that lives in the menu bar. It polls Jira for your assigned tickets, lists the runs and the questions waiting for you, and notifies you when something needs you.

Install it from the sources (needs Xcode, for `swift`):

```sh
./install.sh --from-source
```

The script builds a universal binary, assembles `/Applications/TicketPilot.app` with the version of `.claude-plugin/plugin.json` and a copy of the plugin in `Contents/Resources/plugin` (its manifests, skills, agents, hooks, `bin/`, `ticket_pilot/`, the license, this README and `config.example.json`; never `app/` or `tests/`), signs it ad hoc, quits a running copy and opens the new one. Besides the build folder `app/.build` in the checkout, it writes only `/Applications/TicketPilot.app` (it needs `/Applications` to be writable by you; otherwise it stops and tells you, or drag the app there by hand), removes the old copy at `~/Applications/TicketPilot.app` if there is one, and never uses `sudo`. `swift build` warns that x86_64 is deprecated for the newest macOS target; the warning is expected and harmless. Installing from a release arrives with `/ticket-pilot:setup`.

Install the app; it offers to install or update the Claude Code plugin it carries. When the plugin is missing, or older than the copy in the app, the panel shows "Install the Claude Code plugin…" or "Update the Claude Code plugin (<installed> → <carried>)…" (Settings › Diagnostics has the same as "Install…" or "Update…"). The app first reads `claude plugin marketplace list`, then shows the exact commands it will run and waits for Install:

- if a marketplace named `ticket-pilot` is already configured (for example from GitHub), it stays the source: `claude plugin marketplace update ticket-pilot`, then `claude plugin update ticket-pilot@ticket-pilot` (or `claude plugin install ticket-pilot@ticket-pilot` when the plugin is not installed);
- otherwise the copy inside the app becomes the marketplace: `claude plugin marketplace add /Applications/TicketPilot.app/Contents/Resources/plugin`, then `claude plugin install ticket-pilot@ticket-pilot`.

A failed command is shown with its error output; after a success, restart your Claude Code sessions to use the plugin. A plugin newer than the app's copy (a newer release, a local checkout) is left alone. Installing the plugin alone, without the app, still works: see [Install](#install).

The menu bar shows the app's mark (three stacked chevrons) and, next to it, only what is worth a look: the number of runs that need you, else a "✓" when a report is ready and not opened yet, else nothing (a run in progress adds nothing). A small "!" means a setup problem: the panel says which. The number of tickets to do is not shown there; it lives in the panel.

A click on it opens a panel (it scrolls when it gets tall), from top to bottom:

- a header with the app icon and a gear menu: About TicketPilot, Settings… and Send feedback (opens the project's issues page);
- a footer with Quit (⌘Q), always in sight;
- a status line: "N tickets need you", "Your report is ready 🎉", "Working on it…" with the step, or "All quiet. Enjoy your coffee ☕" with the number of tickets to do ("No ticket assigned"). When the setup must be fixed, it is instead a banner, "Almost there! 👋" with what is missing ("Connect Jira to see your tickets here.") and the button that fixes it, with an arrow ("Connect Jira →"): "Install Claude Code…" (opens its documentation), "Install the Claude Code plugin…" (installs the plugin the app carries, after showing the commands), "Connect Jira…" (opens the Atlassian sign-in, or asks for the token with `jira.auth` `api_token`), "See why Jira refused…" (Atlassian's own message, an administrator block for example), "Allow Keychain access…", "Check again" (Jira unreachable), "Repository not found: <name>…", or "Fix the config…"; last, "Update the Claude Code plugin (<installed> → <carried>)…", since an older plugin still runs. The MCP servers and the disk space are only warnings and never show there.
- **Needs you**: a card per run waiting for you: the ticket's title, a small line "KEY · iOS · Needs you", then "Waiting for your answer: <question>" or "Waiting for your go." / "Waiting for your input.";
- **In progress**: a card per run at work, with its step in plain words and its duration ("Coding · 12 min"), ten dots for the ten steps (filled up to the current one), and a "Maybe stuck" tag when a step runs much longer than usual;
- **Report ready**: a card per finished run, "N commits ready for review" under its "Done" state (the commits of its branch since it left the repo's `main_branch` on `origin`; "Ready for review" while unknown), with no time (it no longer matters), a "Show in Finder" button with the worktree's size and, once the ticket is done in Jira, "Release…";
- **To do**: your tickets to do, by key and summary ("Ready to start" and "Backlog" when both kinds exist), each with Start, and "Open in Jira" in its "⋯" button or its context menu.

Every run card has, at the right of its title, a button that opens its session, named after what the run needs: "Answer" (needs you), "Follow" (in progress), "Read the report" (report ready, even when its session is closed: it is then resumed), or "Resume" when the session of a run not done yet is closed; the notifications use the same names. A card is titled with the ticket's title: the one the plugin recorded (`tp run-set <id> --title`, at step 1), else the ticket's summary in Jira, else its key (then shown once, as the title, and not repeated in the small line under it); repos read as their platform (ios as iOS, android as Android, web as Web). VoiceOver reads each card with its ticket, the progress as "Step N of 10" with the step, and each button with the ticket it acts on. Settings and About close with ⌘W. Runs are listed the most recently updated first; the repo is named after the key only when a ticket has runs in several repos.

**Settings…** opens a small window with Open at login, the terminal sessions open in ("Automatic (<the one detected>)" or one of the known terminals installed, or Terminal; the choice is saved as `terminal_app` in your config, every other key kept, and "Automatic" removes the key), Diagnostics (every setup check with ✓ or ✗, its detail, its fix command to copy, and "Set Jira token…" when needed; the plugin line reads "installed <version> · bundled <version>") and Check again. **About TicketPilot** shows the version, the copyright, the license and a link to the source (the issues are behind Send feedback).

By default (`jira.auth` absent or `mcp`), the app reads Jira through the Atlassian Remote MCP server (`https://mcp.atlassian.com/v1/mcp`), the way Claude Code does, so it also works where an organisation blocks API tokens. Choose "Connect Jira…" in the panel (or in Settings › Jira): your browser opens the Atlassian sign-in and the panel reads "Waiting for Atlassian sign-in…" with Cancel. Once you allow access, the page says to return to TicketPilot (the listener only accepts the callback of this sign-in) and the app checks the setup again and reads your tickets. Under the hood: OAuth 2.1 with dynamic client registration of a public "TicketPilot" client, PKCE (S256) and a one-shot listener on `127.0.0.1` (random port, closed after the callback or five minutes); the sign-in (client id, access and refresh tokens, expiry) is one Keychain item of the service `ticket-pilot-atlassian-mcp` (this Mac only, readable while it is unlocked), refreshed when it expires, never written to a file or a log. Jira is then read with the server's `getAccessibleAtlassianResources` (the site of `jira.site`), `searchJiraIssuesUsingJql` and `atlassianUserInfo` tools, the only ones the app calls. If Atlassian refuses (an administrator block, a consent not given), the panel shows its message. Settings › Jira shows "Connected as <email>" with Disconnect (deletes the Keychain item and asks Atlassian to revoke the tokens), and "Use an API token instead…", which saves `jira.auth` as `api_token` in your config and asks for the token.

With `jira.auth` set to `api_token`, if the Jira token is missing, choose "Connect Jira…" in the panel (or "Set Jira token…" in Settings) to enter it: it is stored in the Keychain under the `jira.keychainService` of your config (account: your user name). The "Connect Jira" dialog explains the three steps: "Create a token" opens the Atlassian page where API tokens are made (the dialog stays open), create and copy the token, then paste it and choose Save. "Use the Atlassian sign-in instead…" in Settings › Jira switches back.

The icon source is `app/Resources/AppIcon.svg`; `app/Resources/make-icon.sh` regenerates `app/Resources/AppIcon.icns` from it.

Sessions open in the terminal you already use: `terminal_app` if set, otherwise the known terminal hosting a running `claude`, the only known terminal installed, or the app macOS opens `.command` files with (else Terminal); Settings shows which one. The session button of a run card opens its session, depending on the session: if it has ended (the plugin's `SessionEnd` hook records this) the app resumes it in a new terminal window, if the run has no session it starts one, and if the session is still running or waiting it brings your terminal to the front. With Ghostty 1.3 or later as your terminal (set as `terminal_app` or detected), a click instead focuses the tab whose folder matches the session (using the folder the plugin's hooks last saw it in), or, when no tab matches, resumes the session in a new tab; the first time, macOS asks to let TicketPilot control Ghostty (System Settings › Privacy & Security › Automation), and without it the app falls back to the behaviour above. A session closed without the `SessionEnd` hook (a killed terminal, an older plugin) still shows as open with a terminal other than Ghostty, and is only detected as closed once the plugin with that hook is installed.

What it reads:

- the run files `runs/*.json` in the state directory (`~/Library/Application Support/ticket-pilot/`, or `TICKET_PILOT_HOME`);
- your config (`~/.config/ticket-pilot/config.json`, or `TICKET_PILOT_CONFIG`);
- your Atlassian sign-in, from the Keychain service `ticket-pilot-atlassian-mcp` (with `jira.auth` `mcp`), or your Jira API token, from the Keychain service named by `jira.keychain_service` (with `api_token`). Neither is ever written to a file or a log.
- the disk usage of each finished run's worktree (with `du`), shown on that run's "Show in Finder" button;
- the number of commits of each finished run (`git merge-base HEAD origin/<main_branch>` then `git rev-list --count`, in its worktree), shown on its card.

What it writes:

- its own state in `app/` inside the state directory (tickets already seen, acknowledged questions, helper scripts);
- your config, only when you pick a terminal or switch the Jira connection in Settings: it sets or removes `terminal_app`, or sets `jira.auth`, and keeps every other key in place (the file is rewritten pretty-printed, two spaces);
- when you choose "Release…" for a finished ticket: it removes that run's worktree, then its branch, then its run file, and stops at the first step git refuses. A worktree with uncommitted changes is kept, and so are the branch and the run file. A branch that is not merged is kept with the run file, but the worktree is already removed at that point; the alert gives the `git branch -D` command to run yourself, then "Release…" again finishes the job. It never deletes the repo's main branch or the branch checked out in the repo.

It only reads Jira: it never transitions a ticket, comments or edits a field. It never launches `claude` without a click: a session starts only when you choose it in the panel. The one exception is the setup check, which runs `claude mcp list` when the app starts and on "Check again" (Settings) to see whether the Atlassian and Figma servers are connected. Installing or updating the plugin runs `claude plugin` commands only after you click its button and confirm the commands listed.

Permissions: the first launch asks to allow notifications (System Settings > Notifications > TicketPilot). The app is signed ad hoc, so macOS may ask again to allow it to read the Atlassian sign-in or the Jira token from the Keychain after each reinstall; choose Allow (or Always Allow), then "Check again" in Settings. The app turns on "Open at login" the first time it starts; you can turn it off in Settings.

Uninstall: uncheck "Open at login" in Settings, quit the app, then delete `/Applications/TicketPilot.app` (and `~/Applications/TicketPilot.app` if an older install left one). Its state in `app/` can be deleted too; the runs are not affected.

## Install

Requirements:

- macOS
- `/usr/bin/python3` (installed with the Command Line Tools: `xcode-select --install`); only the standard library is used
- git
- The Atlassian and Figma MCP servers are recommended for step 1 (reading tickets, Confluence pages and designs). Without them the skill lists those sources as unread.

The simplest path on macOS is the [menu bar app](#menu-bar-app): install the app; it offers to install or update the Claude Code plugin it carries. To install the plugin alone, from a marketplace (replace `<owner>` with the GitHub owner hosting this repository):

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
| `jira.auth` | no | How the menu bar app reads Jira: `mcp` (sign in to the Atlassian Remote MCP server in the browser, no API token) or `api_token` (REST API with the token of `jira.keychain_service`) | `mcp` |
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
| `repos[].ci_review_command` | no | Command, run from the worktree, that replays your CI review bot locally on one commit (same context, prompt, output schema and call as the CI job) and prints its comments without posting them. Receives `TP_REV` (commit), `TP_BASE` (base commit) and `TP_WORKTREE`. Run once per commit in step 9: it may cost what one CI review costs | none: only the reviewer runs, and the report says the CI chain was not replayed |
| `backend.repos` | no | Backend checkouts read in step 3 | `[]` |
| `backend.api_docs` | no | API documentation paths read in step 3 | `[]` |
| `sync_command` | no | Command that syncs a repo before a worktree is created | `git fetch origin` |
| `reviewer_agent` | no | Agent type used as reviewer | `ticket-pilot:reviewer` |
| `auditor_agent` | no | Agent type used as auditor | `ticket-pilot:auditor` |
| `terminal_app` | no | Terminal application used by the menu bar app to open sessions | else the known terminal (Ghostty, iTerm, Warp, WezTerm, kitty) hosting a running `claude`, else the only one of them installed, else the app macOS opens `.command` files with, else Terminal |
| `permission_mode` | no | Claude Code permission mode used by the menu bar app to start sessions | none |
| `max_commit_lines` | no | Review size threshold: added plus removed lines per commit | `999` |
| `generated_globs` | no | Files excluded from the commit size count | `[]` |
| `snapshot_globs` | no | Snapshot files excluded from the commit size count | `["**/__Snapshots__/**"]` |
| `poll_minutes` | no | Polling interval in minutes, for the menu bar app | `5` |
| `stuck_minutes` | no | Minutes after which a running step shows "Maybe stuck" in the menu bar app, by step name (`implement`, `verify`, ...) | built-in per-step thresholds |
| `ready_statuses` | no | Jira statuses meaning a ticket is ready to start, for the menu bar app | `["To Start"]` |

## Replaying your CI review

If your CI runs an automatic review on each change (for example an AI review bot), ticket-pilot can replay it locally on each commit before you send anything, so that the bot has nothing left to comment.

- **Without configuration**: in step 9, the skill looks for the review job in the repo's CI definitions, reads how it builds its context, its prompt, its output schema and its call, and proposes a command that replays it without the publishing step. It runs it only after your yes, and offers to save it as `ci_review_command`.
- **Your own command**: set `repos[].ci_review_command`. Keep the script next to your config file (for example in `~/.config/ticket-pilot/`), not in the repo. It must:
  1. build the same context as the CI job, for the commit `$TP_REV` against `$TP_BASE`;
  2. call the same model with the same prompt, output schema and limits;
  3. print the comments, one per line or as the CI's JSON output;
  4. **never post, comment or vote anywhere**: drop the CI's publishing step;
  5. exit with a non-zero code when the review could not run.

Skeleton, to adapt to what your CI job does:

```sh
#!/bin/sh
set -eu
cd "$TP_WORKTREE"
context=$(mktemp)
trap 'rm -f "$context"' EXIT
{
  git log -1 --format=%B "$TP_REV"
  git diff "$TP_BASE" "$TP_REV"
} > "$context"                       # replace with your CI's own context script
cat path/to/ci-review-prompt "$context" \
  | claude --print --output-format json \
      --json-schema "$(cat path/to/ci-review-schema.json)"
```

Each replay costs what one review of your CI costs, once per commit and per verification pass.

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
