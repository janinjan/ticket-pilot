---
name: start
description: Start or implement a Jira ticket end to end. Reads the ticket and every linked source, waits for a go, then prepares a worktree, researches the other platforms and the backend, implements behind a feature toggle, verifies, tests in the app, reviews, audits and produces verified, review-ready commits with a final report. Use when the user asks to start, implement, pick up or resume a Jira ticket, or runs /ticket-pilot:start <KEY>.
argument-hint: "<JIRA-KEY>"
---

# ticket-pilot: start a ticket

The ticket key `<KEY>` is the first word of `$ARGUMENTS`, in uppercase. If `$ARGUMENTS` is empty, run `"<plugin-root>/bin/tp" run-list` (one line per run: id, status, step, step name, worktree), show the user the runs whose status is not `done`, ask them to run `/ticket-pilot:start <KEY>` with the key of the one to resume (or of a new ticket), and stop there. If `<KEY>` does not fully match `[A-Z][A-Z0-9]+-\d+`, tell the user it is not a valid ticket key and stop there.

Session tracking only works when the skill is invoked as `/ticket-pilot:start <KEY>`, with the key in uppercase right after the command; if the user started it another way, tell them so.

This file is written in English, but **you write to the user only in the language decided at the start** (see below). Language rule, checked before every message:

- Decide the user's language once, at the start: the language instructions of the user's own instructions (CLAUDE.md, memory) win; otherwise the language of the user's messages. Record it right after the run exists: `"<plugin-root>/bin/tp" run-set <id> --language <code>` (`fr`, `en`, `pt-BR`…). On resume, read `language` in `run-show` and reuse it; do not decide again. Keep it for the whole run: a one-word reply ("go", "ok", "yes") never changes it, even though the word is English; only an explicit request of the user does.
- Every sentence the user sees is in that language and register (if the user says "tu", say "tu"): one-line progress narration between tool calls, questions, summaries, tables, the test plan and the final report. No English sentence, not even a short "Checking the build".
- Before EVERY message to the user, check that it is in the recorded language. This matters most for what is written right after a long tool or agent output: status summaries, errors and blockers. The drift happens there.
- Agent and tool outputs often come back in another language (English): translate what you show, never paste or echo them.
- Code, commands, file paths, identifiers and quoted error messages stay as they are.

## Absolute rule

**Nothing visible to others without an explicit yes.** Without an explicit yes from the user, for that exact action, in this session, never:

- push a branch or a commit;
- open a pull request or a change for review;
- post a review comment or any other comment;
- vote on a review;
- make a Jira transition or post a Jira comment (or change any Jira field);
- send a Slack message (or any other message);
- any other action that someone else can see or that changes a shared system (code review tools, issue tracker, wiki, chat, design tool), for example adding reviewers, setting a topic or a work-in-progress flag, creating or linking tickets, editing pages, adding reactions.

A yes for one action never covers another one. This skill itself never needs any of these actions: it stops at local commits and prints the command that sends them.

## Failures, even if it works

Each of these makes the run a failure, whatever the result:

- an action visible to others without a yes;
- a step skipped silently;
- extra tests, in particular a dedicated test for a single value when an existing test of the same object already checks its other values;
- changes nobody asked for: cosmetic changes, refactoring or reformatting; superfluous comments; existing comments or TODOs removed; untracked files left behind; changes to a demo or sample app;
- a behaviour change in production when the feature toggle is OFF;
- a change in a module owned by another team;
- a claim or a decision without proof. What you have no proof of, do not do.

## How to run this skill

**The CLI.** When this skill loads you are told its base directory (`…/skills/start`). `<plugin-root>` is the directory two levels above it. Every `tp` call below is written `"<plugin-root>/bin/tp" …`: replace `<plugin-root>` with that absolute path. Do not rely on an environment variable to find it.

**The config.** Read the config file with the Read tool: `$TICKET_PILOT_CONFIG` when set, else `~/.config/ticket-pilot/config.json`. In the steps below, "the repo entry" is the entry of `repos` chosen at start-up. Optional keys, used when present: on the repo entry `setup_command`, `sync_command`, `launch_skill`, `ci_review_prompt` (a path relative to the repo root), `ci_review_command`, `guidelines` (folders or files of team conventions kept outside the repo, `~` allowed); at the top level `sync_command`, `reviewer_agent`, `auditor_agent`, `backend.repos`, `backend.api_docs`, `max_commit_lines`.

**Settings worked out.** When the run works out a setting the repo entry does not have yet, note it with its proof, for the end of the report: `setup_command` (the command that set the worktree up in step 2, found in the repo's README, Makefile or build skill), `launch_skill` (the skill that built and launched the app in step 7), `guidelines` (team conventions found outside the repo, used in steps 3 and 5), `backend.repos` and `backend.api_docs` (the backend checkout or API docs read in step 3, at the top level of the config). Never save one during the run: they are offered once, at the end of step 10. `ci_review_command` keeps its own question, in step 9.

**The user's memory for this repo.** Claude Code loads the user's memory only for the directory the session started in: a session started in the worktree or in another directory does not see the memory of the repo, and a loaded index is not a rule applied. So read it yourself, at start-up and on resume: the folder is `~/.claude/projects/<name>/memory/`, where `<name>` is the main repo root with every non-alphanumeric character replaced by `-` (for example `/home/a.b/dev/app` gives `-home-a-b-dev-app`). Read its `MEMORY.md` and every file it links about code, naming, vocabulary, tests or commits. No such folder → say so once and carry on. Go over these rules again before naming anything (the branch in step 2, every symbol in step 5, every commit subject in step 9) and before splitting the commits: a rule of the memory wins over a default of this skill, for example the order or the grouping of the split.

**The worktree.** Bash `cd` outside the session's working directory may not persist between calls. Every command for the worktree is either `cd "<worktree>" && …` in the same call or `git -C "<worktree>" …`. Every file edit uses an absolute path inside the worktree. Never edit the main checkout. Every build, test, setup, generation or `ci_review_command` command in the worktree goes through `"<plugin-root>/bin/tp" run-shell <id> '<command string>'` (the whole command as ONE quoted string): it runs in the worktree, with the run's `env` from the repo entry, inside the user's login interactive shell (`$SHELL -l -i -c`), so the user's version managers and PATH are loaded; Claude's Bash tool alone does not load them (wrong Ruby or Node, failed generation). Its stdin is empty and its exit code is the command's. Plain `git` commands do not need it. `tp run-env <id>` (export lines) remains for the cases where you need the variables yourself.

**Autonomy.** Before asking the user anything, look for the answer yourself, wherever you have access: the app you drive (navigate it to find test data, for example browse "My ads" for an existing item to edit), the repo, the config, the tools (the proxy's CLI or export to list its active rules, the simulator, the repo's build skill). A tooling failure is not a question: retry with `"<plugin-root>/bin/tp" run-shell`, the repo's build skill or a regeneration first. Ask only for (a) a decision that belongs to the user (divergence, scope, product), (b) an action visible to others, (c) something you genuinely cannot obtain, and then say what you already tried.

**Questions.** Following the autonomy rule above, ask only for decisions that change what gets built: a real divergence between sources, a real ambiguity, a conflict between the design and the ticket. One question at a time, always with your recommendation. Every question to the user (the go, a divergence, a branch reference, launching the app, any choice) is recorded first with `"<plugin-root>/bin/tp" run-wait <id> <kind> "<the question text, in the user's language>"`, the text of the question itself, never an empty text; the steps below repeat it where it applies. Then wait for the answer. A reply that does not answer the question (the user talks about something else, comments on another point, says only "ok" to a question with several options) is neither a yes nor a no: answer what they said, then ask the question again in one sentence. Until it is answered, it stays open: a decision you take meanwhile is yours, listed as such in the report with ❓, and you never write that the user decided, chose or validated it.

**Proof.** Every claim you make, during the run and in the report, comes with its proof: `path:line`, the command and its output, or a link. If you cannot prove it, say so and mark it ❓.

## Start-up

1. Run `"<plugin-root>/bin/tp" config-check`. If it does not print `OK`, show the user every problem it printed and stop.
2. Find the current repo. Run `git rev-parse --path-format=absolute --git-common-dir`; the main repo root is the parent of the `.git` directory it prints (this also works from inside a worktree). Resolve it and each config `path` (expand `~`, resolve symlinks with `cd "<path>" && pwd -P`). The repo entry is the one whose `path` equals the main repo root. If none matches, tell the user that this repo is not in the config and stop.
   - Not inside a git repo (the command fails): run `"<plugin-root>/bin/tp" run-list`. If exactly one run of `<KEY>` exists, its id ends with `--<repo-name>`: use that repo entry, and its `path` as the main repo root. Otherwise, ask the user to start Claude Code from the repo of the ticket, and stop.
3. Check whether a run already exists: `"<plugin-root>/bin/tp" run-show <KEY>--<repo-name>`.
   - Unknown run (exit code 2): run `"<plugin-root>/bin/tp" run-start <KEY> <repo-name> "<main repo root>"`. It prints the run id (`<KEY>--<repo-name>`). Keep it: it is the `<id>` of every later `tp run-*` call.
   - Existing run with `status` `done`: tell the user the run is finished and offer to show its report again. Do not start over. If they say yes, repeat the report if this session still has it; otherwise rebuild it from the run state and the branch (`git -C "<worktree>" log --oneline <base>..HEAD`), marking ❓ what you cannot prove again.
   - Existing run not done: tell the user at which step it stopped (`step`, `step_name`, `waiting`) and offer to resume there. Never restart silently, never restart without a yes. See Resume below.
4. Create the checklist with TaskCreate: one task per step, `Step 1 — Understand` to `Step 10 — Report`. Every step is mandatory. When the task tool is not available, do not mention it to the user: track progress with `run-step` only.
   - Before starting step N, run `"<plugin-root>/bin/tp" run-step <id> N` and mark the task in progress when the checklist exists.
   - A step that does not apply is still started with `run-step`, then checked as "not applicable" with its reason (for example "no user interface change: nothing to launch"). Never skip a step silently.

## Step 1 — Understand

Run `"<plugin-root>/bin/tp" run-step <id> 1`.

1. Read the whole ticket with the Atlassian MCP tools, the only way ticket-pilot reads Jira (there is no API token). When they are not available or fail, say so, tell the user to connect the Atlassian MCP server in Claude Code (`/mcp`) and stop: never guess the ticket.
   - description and acceptance criteria;
   - **every comment**: a late comment often changes the scope ("in the end we do X");
   - attachments, linked tickets, the parent epic.

   Record the ticket's title, as written in Jira, for the menu bar app: `"<plugin-root>/bin/tp" run-set <id> --title "<title>"`.
2. Read **every** Confluence page linked from the ticket, images included, every Figma link, and every linked Slack thread. If a source cannot be read (missing tool, no access, an attachment the tools cannot download), list it as unread; never guess its content, not even from the description. In the message of point 4, ask the user to paste each unread source the user can provide (an attachment, an image, a private page) or to say it can be ignored; until then, the requests it may touch are marked ❓.
3. Write the **numbered list of requests**: one request per number, each with its source (ticket description, comment, Confluence page, Figma frame…). Record it, in order, one flag per request: `"<plugin-root>/bin/tp" run-set <id> --request "<1. request — source>" --request "<2. …>"`. Record it again whenever the list changes (an answer of the user, a resume).
4. Present to the user: a short summary, the numbered requests, the target repo, and the ambiguous points.
5. Ask in the same message, in the user's language, whether to add the line `JIRA: <KEY>` to the commits. The line is never added without a yes.
6. The test in the app at step 7: check yourself whether you can drive the app, never ask the user and never assume. MCP tools are often loaded only on demand, so look for them by what they do, not by a name: run ToolSearch with `tap screenshot device` and see whether tools that tap and take screenshots on a simulator or emulator come back (for example `mcp__mobile-mcp__…`); when unsure, `claude mcp list` shows the servers and whether they are connected. On an Android repo, `adb version` answering is enough. If you can, do not ask: say in the same message, in one line, that you will test in the app yourself at step 7 and that they need not be there. If you cannot, ask in the same message whether they run the cases with you at step 7 or leave the test to them for later, so the run goes on to the commits without it; recommend leaving it when they said they will not be there.
7. Record the wait, then wait: `"<plugin-root>/bin/tp" run-wait <id> go "<in the user's language: one-line summary + the question about the JIRA line + the app test line or question of point 6>"`. This go is the only systematic validation of the run. Nothing else starts before it.
8. On the go, record the answers: `"<plugin-root>/bin/tp" run-set <id> --jira-line yes` or `--jira-line no`, and `--app-test yes` or `--app-test no`: `yes` when you drive the app yourself or they chose to run it with you, `no` when they left it for later or wrote that you skip it; no answer about it: `yes`.
9. When the user asks at the go only to test the ticket in the app (a non-regression check of what is already merged, "test only"), record `"<plugin-root>/bin/tp" run-set <id> --test-only yes` and follow Test only below.

## Step 2 — Prepare

Apply the autonomy rule: a missing path, tool or setup is found in the repo and the config, or retried with `tp run-shell` and the repo's build skill, before any question.

Run `"<plugin-root>/bin/tp" run-step <id> 2`.

1. Sync the main repo: run `sync_command` (repo entry first, then top level) from the main repo root. Without one: `git -C "<repo>" fetch origin`.
2. Choose a branch name: a short descriptive slug of the change, in kebab-case, **without the ticket number** (for example `show-delivery-distance`). Name the feature with the term the code already uses for it (an existing toggle, type or field name, found with `git -C "<repo>" grep -i "<term>" origin/<main_branch>`), not with a synonym from the ticket that appears nowhere in the code.
3. Create a dedicated worktree at `<repo-path>-worktrees/<slug>` (sibling of the repo; avoid spaces in the path), always from the up-to-date remote main branch: `git -C "<repo>" worktree add --no-track -b <slug> "<worktree>" origin/<main_branch>`.
   - If that path or branch already exists and belongs to this run (the run's recorded `branch` is `<slug>`, or the path equals the run's recorded `worktree`), reuse it: do not create it again.
   - If it belongs to something else, never touch it: propose another slug as a question, `"<plugin-root>/bin/tp" run-wait <id> question "<in the user's language: slug X is taken, use slug Y? + recommendation>"`, and wait for the answer.
4. Note the base commit: `git -C "<worktree>" merge-base HEAD origin/<main_branch>`. It is `<base>` in every later step.
5. Record it: `"<plugin-root>/bin/tp" run-set <id> --worktree "<worktree>" --branch <slug>`.
6. Set up the worktree: `"<plugin-root>/bin/tp" run-shell <id> '<setup_command>'` (like every command in the worktree), or the repo's own build skill when it handles project generation itself.
7. If any of this fails: stop, report what failed with its output. Do not improvise a workaround.

## Step 3 — Research

Run `"<plugin-root>/bin/tp" run-step <id> 3`.

Launch **six read-only exploration agents in parallel**, in a single message (for example the `Explore` agent type), one per research item below. Give each one: the ticket key and title, the numbered requests, the worktree path, the relevant config entries, the absolute rule (nothing visible to others without an explicit yes: no comment, no vote, no Jira or wiki change, no message, nothing that changes a shared system), the instruction to stay read-only and to return every finding with its proof (`path:line`, link, command), and the language rule: write the report in the user's language (the one decided at the start), so that nothing in English reaches the user.

1. **Twin tickets** on the other platforms: search Jira for the ticket title without its platform prefix (the `match.title_prefixes` of every repo in the config). Read their descriptions: they often differ.
2. **The other platforms' implementation, where it really is**. The agents run in parallel, so this agent finds the twin tickets itself (same search as item 1), then, depending on each twin's status:
   - done → merged code in the other repos of the config, read from their remote main branch, never their working tree (it may hold someone's local, unmerged work): `git -C "<repo>" log origin/<main_branch> --grep "<term>"` and `git -C "<repo>" grep "<term>" origin/<main_branch>`;
   - in progress or in review → open pull requests or review changes, **work-in-progress ones included**, flagged as not final;
   - read their **tests** too: they hold the exact expected values.
3. **Backend contract**: confirm every consumed field: exact name, type, nullability, computed by the backend or by the client. Sources: `backend.api_docs` and `backend.repos`. Never deduced from front-end code alone.
4. **Precedents** in the target repo: an analogous feature already shipped; the git history ("how was it done for X?", who and when, with `git log` and `git blame`); how colleagues did the same thing.
5. **The target module's architecture**: the module's own architectural choice is the reference, not only the neighbouring file. **When in doubt, look at the whole codebase.** When the repo entry has `guidelines`, read the parts that cover this kind of change (architecture, conventions, testing) and quote them with their `path:line`.
6. **Local work in progress**: in the target repo and in the other platform repos, someone (often the user) may already have an unpushed local branch on this ticket. For each repo:
   - list the local branches with their last commit date: `git -C "<repo>" for-each-ref refs/heads --sort=-committerdate --format='%(refname:short) %(committerdate:short) %(subject)'`;
   - match the branch names of that list against the ticket key and the topic keywords;
   - search the unmerged commits of every local branch by message, for the ticket key, the feature toggle name and the topic keywords: `git -C "<repo>" log --branches --not origin/<main_branch> --source -i --grep "<term>"` (`--source` prints the branch each commit was reached from);
   - search each branch's own changes, never its whole content (a term already on the main branch would match every branch): `git -C "<repo>" log origin/<main_branch>..<branch> -i -G "<term>" --oneline` and `git -C "<repo>" diff origin/<main_branch>...<branch> | grep -i "<term>"`;
   - a feature toggle that exists on the main branch but that nothing reads is a strong clue that the work exists elsewhere: look for the branch whose own changes read it.
   A candidate branch is a local branch whose name matches, or whose own commits match by message (`-i --grep`) or by change (`-G`). Exclude the run's own branch (`<slug>`, created in step 2). Unmerged local work is reported as local, not as merged: merged code is only what item 2 reads from `origin/<main_branch>`.

If an agent finds no implementation on a platform, rerun the sync for that repo yourself (its `sync_command`, else `git -C "<repo>" fetch origin`), then search `origin/<main_branch>` again before concluding "not started".

If item 6 finds a candidate branch, record it and ask ONE question, with your recommendation: `"<plugin-root>/bin/tp" run-wait <id> question "<in the user's language: is branch X (repo, last commit date) the reference for this ticket? + recommendation, yes or no and why>"`, then wait for the answer. If yes, that branch is the **primary reference**: compare against it in step 4 and reuse its logic and design rather than re-inventing them.

When the research shows that every request is already on `origin/<main_branch>` (merged on the target platform), do not implement it again: say so with the proof (the commits, `path:line`) and offer to test the current main branch in the app instead, with `"<plugin-root>/bin/tp" run-wait <id> question "<in the user's language: everything is merged (proof); test it in the app instead, as a non-regression check? + recommendation>"`. On a yes, record `--test-only yes` and follow Test only. On a no, report what is merged and end the run.

## Step 4 — Compare and decide

Run `"<plugin-root>/bin/tp" run-step <id> 4`.

Show the table to the user before step 5, even when nothing diverges (then say so in one line under it): it is what the report's alignment is checked against.

1. Build a **table**, one row per aspect (API field, scope, empty or null value, wording, rendering…), one column per source:

   | Aspect | Web | iOS | Android | Back | → target |
   |---|---|---|---|---|---|

   The platform columns are examples: use the platforms that exist for this ticket. When step 3 found a local work-in-progress branch, add a **Local branch** column for it (marked local, not merged); when the user chose it as the reference, it is the primary reference of the table. Every cell carries its proof.
2. Ask **one question per real divergence** of behaviour, scope or data, with your recommendation, recorded first with `"<plugin-root>/bin/tp" run-wait <id> question "<in the user's language: the divergence + recommendation>"`. Differences imposed by the platform itself do not count.
3. Only one reference found → follow it, and say so.
4. No reference at all (the target platform is the first) → **carry on**: build the spec from the ticket, the twins, the backend, the precedents and the design; take the decisions yourself and list them for the report; ask only on a real product ambiguity.
5. Reproduce the **behaviour**, not the code structure of the other platforms.

## Step 5 — Implement

Run `"<plugin-root>/bin/tp" run-step <id> 5`.

- Follow the repo's instructions (`CLAUDE.md`, `AGENTS.md`, linked docs), the repo entry's `guidelines` (the parts that cover the change), the user's memory for this repo, and the module's architecture.
- **New behaviour behind a feature toggle**, following the repo's toggle conventions. With the toggle OFF, the current production behaviour stays exactly the same. Exception: when the ticket itself is the clean-up of a toggle, no new toggle is created; the clean-up keeps the toggle-ON behaviour and removes the toggle and its OFF path.
- Simple but professional code, senior level: no duplication, no needless extension or helper, no superfluous abstraction.
- Do not touch any module owned by another team (check the repo's ownership files or instructions; ask when unsure).
- Tests following the repo's and the user's conventions, with realistic values.
- Nothing from "Failures, even if it works": no unrequested change, no extra comment, no removed comment or TODO, no stray file.

## Step 6 — Verify

Apply the autonomy rule: a build, test or generation failure is retried with `tp run-shell`, the repo's build skill or a regeneration before you report or ask anything.

Run `"<plugin-root>/bin/tp" run-step <id> 6`.

1. **Build** with the repo's build command or build skill.
2. **Tests**: run them and make them pass.
3. **Snapshots**: only those of the impacted views, regenerated, and kept in the same commit as the change they reflect.
4. **Test necessity**:
   - every added test is useful;
   - no dedicated test for a single value when an existing test can take one more line;
   - no test for an impossible scenario;
   - existing tests are not renamed, unless the change makes one fall under a naming rule of the repo or of the user's instructions or memory (a suffix for a toggle ON, for example): then that rule wins, and the report says which test was renamed and why.
5. **Toggle OFF = production**: prove, by reading the diff (`git -C "<worktree>" diff <base>`) and by the tests, that with the toggle OFF no behaviour changes. Quote the lines that prove it.

## Step 7 — Test in the app

Run `"<plugin-root>/bin/tp" run-step <id> 7`.

This step is "not applicable" only when the change has no effect visible in the app, and the reason must cite the diff that shows it (for example "only `path:line` of the build scripts changes").

When the run's `app_test` is false (the user chose at the go to test later, see `"<plugin-root>/bin/tp" run-show <id>`), the test is left to the user: check the step as "not applicable: left to the user at their request", launch nothing and ask nothing. Still write the test plan of point 6, every result ❓ (not run), and the Coverage list of point 7, so the report hands the user the plan to run; then go on to step 8. The user can still change their mind later and ask you to run it.

For the whole step, apply the autonomy rule: find test data yourself by navigating the app you drive (for example an existing ad to edit under "My ads") instead of asking. Once the app runs on a device, simulator or browser that the user launched (or said is ready), never install, reinstall, rebuild or relaunch it there without an explicit yes for that exact action. A short or ambiguous reply ("ok", "done") to a question that offered several actions means ready, not permission to act. When in doubt, ask again in one sentence.

1. Build, install and launch the app on a simulator, emulator or browser of your own (never on one the user launched, see above):
   - with the repo entry's `launch_skill`, or the repo's own launch skill if it has one;
   - else with the platform's standard commands, each through `"<plugin-root>/bin/tp" run-shell`:
     - Android: when no emulator runs (`adb devices`), start one of `emulator -list-avds` with `emulator -avd <name>` and wait for it (`adb wait-for-device`, then `adb shell getprop sys.boot_completed` is `1`); install the debug variant with its Gradle install task (`./gradlew tasks --group install` lists them, for example `./gradlew :app:installDebug`); launch it with `adb shell monkey -p <applicationId> 1`;
     - iOS: generate the project first when the repo generates it (XcodeGen, as its `CLAUDE.md` says: a new worktree has none), build the app's scheme for the simulator with the repo's build (its build skill, else `xcodebuild -scheme <app> -destination 'platform=iOS Simulator,id=<udid>' -derivedDataPath <dir> build`; the first build of a worktree is long), boot a simulator when none is booted (`xcrun simctl boot <device>`), then `xcrun simctl install booted <path to the .app>` and `xcrun simctl launch booted <bundle id>`;
     - web: the repo's own development server command (its `package.json` scripts), then open the page.
   What you test, whatever builds it:
   - the app the users get, from its main scheme or target (on iOS the app's own scheme, not a framework's), never a module's demo app, unless the ticket is about that demo;
   - built from the worktree, into a build folder inside it (`-derivedDataPath "<worktree>/dd"`), never a build made elsewhere or prebuilt modules: say in the test plan which commit the build comes from. Whenever the worktree moves to another commit (another branch, `origin/<main_branch>` for a check), reset what the repo injects or caches between builds (a module injector's leftovers, a project setup file marking modules as injected), generate the project again and rebuild; then check that the modules the ticket touches were compiled from that commit before running a case;
   - on a test environment, never production: launch with the enabled environment variables of the app's run scheme (`_APP_ENVIRONMENT_` for example, passed with `SIMCTL_CHILD_` on iOS), and name the environment in the test plan;
   - when a case needs a signed-in account, never ask for a password or accept one in the conversation: ask the user once to sign in themselves on your device (they see it in the simulator app), with `"<plugin-root>/bin/tp" run-wait <id> question "<in the user's language: sign in on the ticket-pilot simulator with a test account, then tell me>"`; the sign-in then stays on that device.
   Use a device of your own, the same from one run to the next, and reinstall over it, keeping its data, rather than uninstalling: screens shown once (cookies, onboarding, a sign-in) then stay behind you.
   - iOS: the simulator named `ticket-pilot` (`xcrun simctl list devices`); when there is none, create it once with `xcrun simctl create ticket-pilot <device type> <runtime>`, an iPhone of the runtime the repo builds for. Use never an existing simulator of the user's, booted or not: it holds their own data and sign-ins.
   - Android: an emulator of `emulator -list-avds` that no one is using (`adb devices` shows the running ones); one the user started stays theirs.
2. Drive the app yourself to run the cases. Always tap the element itself, found in an element list read just before (by its reference or its label), never coordinates from an older screenshot: the page may have scrolled since. After each tap, look at the screen again before the next action. Keep a screenshot of what proves each result in the folder that `"<plugin-root>/bin/tp" run-shots <id>` prints, named after its case (`case-1-toggle-on.png`), and cite it in the test plan next to the result. A cookie or consent screen, an onboarding or a "what's new" screen on the way is accepted or closed without asking, unless the ticket is about it; it is not one of the cases.
   - with a device MCP server when one is connected (mobile-mcp, for example: screenshots, element list, taps, swipes, text, on iOS and Android alike). Its tools may be loaded only on demand: look for them with ToolSearch (`tap screenshot device`) before concluding there is none;
   - else on Android with `adb` itself: `adb exec-out screencap -p` for a screenshot, `adb shell uiautomator dump` for the elements and their positions, `adb shell input tap|swipe|text|keyevent`;
   - else on iOS, `xcrun simctl io booted screenshot` gives screenshots but nothing can tap: give the user the cases to run (point 3), with the app already launched.
3. If nothing builds, launches or drives the app, do not tinker: never write your own tooling to drive the app (the commands above are the platform's own, not tooling), and never ask the user to grant system permissions (accessibility, screen recording…) to make one work. When nothing available can drive the app, give the user the numbered cases of the test plan to run, with what to look at, record the wait with `"<plugin-root>/bin/tp" run-wait <id> question "<in the user's language: the cases to run and what to report>"`, and fill the results from their answers and screenshots. Ask the user to launch the app, with the toggle state you need, and wait: `"<plugin-root>/bin/tp" run-wait <id> launch_app "<in the user's language: what to launch and with which toggle state>"`.
   - Toggles: never edit generated or shipped config files to flip a toggle. First look in the repo for how the app takes its toggles at launch, and use it when you launch the app yourself: environment variables of the run scheme (the `EnvironmentVariables` of its `.xcscheme`, for example `_TOGGLES_ON_` and `_TOGGLES_OFF_` with a comma-separated list of keys), launch arguments, or the extras of a debug intent on Android. On iOS, `xcrun simctl launch` passes them on with the `SIMCTL_CHILD_` prefix: `SIMCTL_CHILD__TOGGLES_ON_="<key>" xcrun simctl launch booted <bundle id>`. For the non-regression case, relaunch with the toggle OFF the same way (`_TOGGLES_OFF_`): the app may keep the last values between launches. Only when the app takes none at launch, set it in the app's debug menu while you drive it, or ask the user to.
4. **Proxy state**, before running the cases, when a debugging proxy is in use: list the proxy's active rules (rewrite, scripting, breakpoint, map rules) yourself, with the proxy's own CLI or export; never ask the user to confirm that no rule is active. Read what each rule does yourself, in the proxy's own files or export; never ask the user what a rule does. When a tool refuses to read it, say so and carry on with the traffic export below. Report every rule that alters requests or responses; ask only before disabling one, with with `"<plugin-root>/bin/tp" run-wait <id> question "<in the user's language: may I disable rule X, which alters Y? + recommendation>"` and wait for the answer. Never leave a rule you enabled active. The test plan states that real (unaltered) traffic was used, or which rule altered it.
5. Once the app runs, drive it. Before the first case, list what can change the screens of the ticket and cover it in the plan: the neighbouring toggles that change those screens (each ON and OFF, set at launch as above), the ways in and back (going back, closing without validating, reopening), and the data that changes the result (another address, region, category or size). Then run:
   - validation scenarios for each request;
   - edge cases;
   - **toggle ON, then OFF** (non-regression);
   - network calls, checked yourself: export the captured traffic with the proxy's CLI (a HAR export, for example) and read the requests and responses the cases need; a "Proxy:" check is never left ❓ for want of looking.
   A result stays ❓ (not tested) only for what you cannot drive or reach, with the reason; everything else is run. A behaviour you only read in the code is told as such ("from the code", with `path:line`) and, when the app can be driven, checked in it before you state it as a fact.
6. Write the **test plan in QA format** and record each result ✅ / ❌ / ❓, following `references/test-plan-format.md`: prerequisites, numbered and titled cases (one per request, one per branch added in the diff, real data, "Proxy:" checks), complementary checks (toggle OFF identical to production, out-of-scope cases unchanged) and open questions. The plan has no code references (no file paths, `path:line`, code names or endpoint paths): it is written in plain functional language, with the case ↔ request link as "(Request N)".
7. The plan and its results go into the final report, ready to be pasted as is into a Jira comment by the user, with the path of the screenshots folder: the user attaches its files to the comment. The traceability to the code goes in a separate **Coverage** list of the report: one line per case, case title → request number and/or diff branch (`path:line`).

## Step 8 — Review and audit

Run `"<plugin-root>/bin/tp" run-step <id> 8`.

Make new files visible to the diff first: `git -C "<worktree>" add --intent-to-add <new files>`. The full diff is `git -C "<worktree>" diff <base>`.

1. **Reviewer** on the full diff: agent type `reviewer_agent` from the config, else `ticket-pilot:reviewer`. Give it:
   - the diff (paste it, or for a large one the exact read-only command that prints it, and say it is the whole change);
   - the worktree path;
   - when the repo entry has `ci_review_prompt`: its absolute path (main repo root + the configured relative path);
   - when the repo entry has `guidelines`: their absolute paths.

   The reviewer only applies the CI prompt: it is not the CI review itself, which also builds its own context and output. The CI review is replayed in step 9, on each commit, when the repo entry has `ci_review_command`.
2. Read its answer: line 1 `Score: …`, line 2 the reason. A reason starting with `INPUT MISSING:` is a failure to fix (give the missing input and rerun), never a pass. Every remark, whatever the score, comes as `path:line → problem`; a reason that mentions a remark without listing it is incomplete: ask the reviewer for the lines before going on.
3. **Auditor**, with a fresh context: agent type `auditor_agent` from the config, else `ticket-pilot:auditor`. Give it ONLY the full diff, the numbered list of requests, the worktree path and, when the repo entry has `guidelines`, their absolute paths. No reasoning, no justification.
4. Check each finding against the code. Fix what is confirmed, then rebuild and rerun the tests (step 6 checks), and rerun the agent that raised it until it no longer reports it. A finding you reject is listed in the report with the proof that it is wrong.

## Step 9 — Commits

Run `"<plugin-root>/bin/tp" run-step <id> 9`.

**Message format**: the repo's own commit skill or conventions when present (for example a `commit-msg` skill, or the rules of its `CLAUDE.md`), else Conventional Commits `type(scope): description`, with the scope naming the feature.

- In English, subject only, no body unless the repo's convention requires one.
- The subject names what the commit concretely adds or changes, with the feature's term as the code uses it. Never a generic word standing for the content ("logic", "changes", "update", "misc", "wip").
- Footer `JIRA: <KEY>` only if `jira_line` is true in the run (`"<plugin-root>/bin/tp" run-show <id>`).
- **Attribution line allowed**: you may add the `Co-Authored-By` line the environment provides, unless the repo's conventions or the user's instructions forbid it. No other signature.

**Size and splitting**, detailed in `references/commit-splitting.md`:

1. Check `git -C "<worktree>" status --porcelain`: only files of the change, nothing stray.
2. Stage the whole change and measure it: `cd "<worktree>" && git add -A && "<plugin-root>/bin/tp" commit-size --staged`. It prints `<lines> <class> <ok|over>` against `max_commit_lines` (999 by default; added + removed lines, tests included, generated files and snapshot images excluded).
3. `ok` → one single commit. Never split under the threshold. `over` → split as the reference describes: toggle creation alone first, then data → domain → presentation → view, accessibility last. A toggle clean-up is always one single commit, whatever its size. Before staging the first commit of a split, unstage everything: `git -C "<worktree>" reset -q`.
4. Before every commit, measure what is staged with `cd "<worktree>" && "<plugin-root>/bin/tp" commit-size --staged`; only then run `cd "<worktree>" && git commit -m "<subject>"` (add `-m "JIRA: <KEY>"` only when `jira_line` is true).

**One branch per feature**: the ticket's worktree branch holds all its commits. The user decides how and when to send them.

**Every commit is verified, one by one**, oldest first: build, tests, and the reviewer (step 8 inputs) on that commit's diff only (`git -C "<worktree>" show <sha>`). After every checkout, regenerate what git does not track (project files, generated code) with the repo entry's `setup_command`, or the generation step of the repo's build skill, before building: otherwise the build uses the files of another commit.

- Score -1 or -2 → fix it **as a fixup into that commit**, then verify **the whole chain** again: every commit builds and passes its tests. The exact commands are in the reference.
- **Without `ci_review_command`**, before the first commit is verified, look for the CI review yourself, once per run:
  - search the repo's CI definitions (for example `.github/workflows/`, `.gitlab-ci.yml`, `Jenkinsfile`, or any other CI configuration directory of the repo) for a job that reviews changes automatically, typically with an AI model, and read it to its end: what it gives the model as context (diff, commit message, previous comments, checklist), the prompt, the output schema, the exact call and its limits (turns, budget), and the step that publishes the result;
  - a job only **referenced** there (its name, defined in a shared CI configuration outside the repo) → look for its definition: a local checkout of that shared configuration among the user's repos, then the code review tool and the team chat (read-only search for the job name). If you find the repository, ask before cloning it, then clone it read-only next to the user's repos, never inside the worktree. Not found → tell the user where it is referenced (`path:line`) and ask whether they have its definition;
  - a script of the job that states it also runs locally (its header or documentation says so) → use it as is, with the options that match the CI run, rather than rebuilding the command; still check that it does not publish anything;
  - none found → carry on with the reviewer only; the report says so;
  - found → build the command that replays it locally on one commit: the same context, prompt, schema and call, **without the publishing step** and without anything that writes to a shared system. Ask before running it, with `"<plugin-root>/bin/tp" run-wait <id> question "<in the user's language: the CI review job found (path:line of each part), the command that replays it without publishing, its cost per commit, and whether to save it as ci_review_command in the config + recommendation>"`, and wait for the answer;
  - yes → use it as `ci_review_command` below for this run. Write it into the user's config file only if they said yes to that too; a script it needs goes next to the config file, never into the repo or the worktree;
  - no → reviewer only, and the report says so.
- **CI review replay**, when the repo entry has `ci_review_command` (or the user accepted the one found above), after the reviewer on the same commit:
  - before its first run, read what the command runs (the script and what it calls). If it can post, comment or vote anywhere, do not run it: tell the user and carry on without it;
  - run it with the commit checked out: `cd "<worktree>" && TP_REV=<sha> TP_BASE=<base> TP_WORKTREE="<worktree>" <ci_review_command>`;
  - every comment it prints is a finding: check it against the code, fix a confirmed one as a fixup into that commit (then the whole chain again, as below), reject a wrong one with its proof in the report;
  - a failure of the command (exit code, empty or unreadable output) is never a pass: report it with its output.
- Score 0 or more, a reason not starting with `INPUT MISSING:`, and no confirmed CI comment left → next commit.
- A reason starting with `INPUT MISSING:` → fix the input and re-run the reviewer; it is never a pass.

## Step 10 — Report

Run `"<plugin-root>/bin/tp" run-step <id> 10`.

Write a short report in the user's language, every point with its proof:

- **requests** handled one by one, each with its source: nothing forgotten from the ticket, Confluence or the design;
- **alignment** across platforms: the final table of step 4, unmerged pull requests and review changes included;
- **toggle OFF = production unchanged**, with the proof of step 6;
- the **split** chosen and why, with the list of the branch's commits (`git -C "<worktree>" log --oneline <base>..HEAD`);
- **every commit** builds and passes its tests;
- the **test plan** (format of step 7, no code references) with its results, then the **Coverage** list (case → request / diff branch `path:line`);
- results: tests, snapshots, reviewer score, auditor findings;
- the **CI review**: the comments of `ci_review_command` per commit and what became of each. When it was not replayed (no CI review job found, or the user said no), write it plainly: the CI review was not replayed, only the reviewer applied its prompt, so nothing proves the CI bot will have nothing to comment;
- **decisions taken alone**, open to challenge;
- every ❓ left.

Save the report, word for word as shown to the user, command to send the branch included, so the menu bar app can open it once the session has moved on: `"<plugin-root>/bin/tp" run-report <id> <<'REPORT'` … `REPORT`.

When settings were worked out (see Settings worked out), ask once, after the report: `"<plugin-root>/bin/tp" run-wait <id> question "<in the user's language: save these settings for the next tickets on this repo? + one line per setting, key and value + recommendation>"`, and wait. On a yes, save each one with `"<plugin-root>/bin/tp" config-set --repo <repo-name> <key> "<value>"` (`backend.repos` and `backend.api_docs` without `--repo`), then say what was saved; a setting it refuses (it prints why and writes nothing) is reported with its reason. On a no, save nothing.

Then run `"<plugin-root>/bin/tp" run-done <id>`.

End the report, only when there are commits to send, with the command the user runs to send the branch, chosen by the repo entry's `review`, printed for the user only (do not run it):

- `review` is `gerrit` → `cd "<worktree>" && git review` (print it, do not run it);
- `review` is `github` → `cd "<worktree>" && git push -u origin <branch>` then `gh pr create` (print them, do not run them);
- no `review` (the app could not tell how the repo is reviewed) → give the branch and the worktree, with no command: the user sends it the way this repo is reviewed.

## Test only

A run whose `test_only` is true checks in the app what is already merged: no code, no branch, no commit.

1. Step 2: sync as usual, then make a worktree detached at the remote main branch, with no branch of its own: `git -C "<repo>" worktree add --detach "<repo-path>-worktrees/<slug>-check" origin/<main_branch>`, and record it with `"<plugin-root>/bin/tp" run-set <id> --worktree "<worktree>"` (no `--branch`). Note the base commit as usual.
2. Step 3 as far as needed to know what to check: the toggle, the expected behaviour of each request, the cases the other platforms cover.
3. Steps 4, 5, 6, 8 and 9: start each with `run-step` and check it as "not applicable: test only".
4. Step 7 in full on that worktree, whatever `app_test` says: the test is the point of the run. Toggle ON for each request and its edge cases, then OFF (production unchanged).
5. Step 10: the report holds the requests, the test plan with every result and its screenshots, and the Coverage list pointing at the merged code (`path:line` on `origin/<main_branch>`); no split, no commits and no command to send a branch.
6. The worktree goes with "Remove worktree…" in the menu bar app, as for any run.

Switching, in the same run (a run of the same ticket and repo cannot be started twice):
- **Into test only, at any step**, when the user asks for it after the go: record `--test-only yes`. When this run made a branch that has no commit of its own yet, drop it: `git -C "<worktree>" switch --detach origin/<main_branch>`, `git -C "<repo>" branch -D <branch>`, `"<plugin-root>/bin/tp" run-set <id> --branch ""`. Check the steps left before 7 as "not applicable: test only" and go on with step 7.
- **A regression found**: report it with its proof and ask whether to fix it. On a yes it is fixed in this same run: record `--test-only no`, make the branch in the worktree (`git -C "<worktree>" switch -c <slug>`), record `--branch <slug>`, and go on from step 4 as a normal run, through steps 5 to 10. On a no, it stays a regression in the report.
- **When the user gives up the fix** after that: drop the branch as above (its commits go with it: say so first, with their list, and wait for a yes), record `--test-only yes`, and write the report again as a test-only report.

## After the report

The user often reacts to the report: a naming, a test result to correct, a line to remove. A remark that only corrects the report (a wording of the test plan, a ❓ the user answers) → fix the report and save it again with `run-report`, nothing else. Every change to the report is saved as the full report, rewritten as one consistent text and sent again with `run-report`: never edit the saved report file in place, and never leave a sentence that a later change contradicts.

More testing in the app after the report (cases the user asks for, another platform) reopens the run first: `"<plugin-root>/bin/tp" run-step <id> 7`, then the cases, then step 10 again with the full report: the new cases join the earlier ones, numbered again in one plan, in a logical order, not appended at the end. A worktree, an emulator or a simulator made for that is named in the report, and removed at the end unless the user wants to keep it. A remark that changes the code or the commits reopens the run; never patch it outside the steps:

1. Run `"<plugin-root>/bin/tp" run-step <id> 5`: the run is no longer `done`. Make the change on the branch.
2. Step 6 again (build, tests, toggle OFF).
3. Step 7 again only if what the user sees in the app changes; otherwise start it with `run-step` and check it as not applicable, citing the diff.
4. Step 8 again, **reviewer and auditor** on the new full diff: a rename or a removal can leave dead code or a name that no longer fits.
5. Step 9 again: each change as a fixup into the commit it belongs to, the whole chain verified, the reviewer on every rewritten commit.
6. Step 10 again: what changed since the last report, saved with `run-report` as the full updated report, then `"<plugin-root>/bin/tp" run-done <id>`.

When the test in the app was left to the user (`app_test` false) and they now ask you to run it: record `"<plugin-root>/bin/tp" run-set <id> --app-test yes`, run step 7 in full (`"<plugin-root>/bin/tp" run-step <id> 7`, the app launched as that step says), on the branch as it is. Replace the ❓ of the test plan with the results, save the full report again with `run-report`, then `"<plugin-root>/bin/tp" run-done <id>`. A case that fails is a remark that changes the code: reopen the run as above, from step 5.

## Resume

The run state lives in the ticket-pilot state directory (`runs/<id>.json`): current step, worktree, branch, `jira_line`. When the user accepts to resume an unfinished run:

1. Read it with `"<plugin-root>/bin/tp" run-show <id>`. Check that the worktree and branch still exist only if they are recorded (a run stopped at step 1 or 2 may have none yet). If a recorded one is gone, tell the user and stop.
2. Recreate the checklist when the task tool is available: steps before `step` are done (from `history`), the others are pending.
3. If a worktree is recorded and the run resumes at step 3 or later, recompute `<base>` exactly as in step 2 point 4: `git -C "<worktree>" merge-base HEAD origin/<main_branch>`. Every later step uses this value.
4. Read the ticket again and rebuild the numbered list of requests (step 1 points 1 to 3), then compare it with the recorded `requests`: keep the recorded numbering for the requests that did not change, so that the test plan and the coverage still match. Ask for the go again only if the ticket changed in a way that changes the requests, or if the run stopped at step 1 before the go; keep the recorded `jira_line`.
5. Tell the user you resume step `step` from its beginning, then restart it with `run-step` and carry on from there. A pending question of that step is asked again as the step reaches it.
