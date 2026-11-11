---
name: start
description: Start or implement a Jira ticket end to end. Reads the ticket and every linked source, waits for a go, then prepares a worktree, researches the other platforms and the backend, implements behind a feature toggle, verifies, tests in the app, reviews, audits and produces verified, review-ready commits with a final report. Use when the user asks to start, implement, pick up or resume a Jira ticket, or runs /ticket-pilot:start <KEY>.
argument-hint: "<JIRA-KEY>"
---

# ticket-pilot: start a ticket

The ticket key `<KEY>` is the first word of `$ARGUMENTS`, in uppercase. If `$ARGUMENTS` is empty, run `"<plugin-root>/bin/tp" run-list` (one line per run: id, status, step, step name, worktree), show the user the runs whose status is not `done`, ask them to run `/ticket-pilot:start <KEY>` with the key of the one to resume (or of a new ticket), and stop there. If `<KEY>` does not fully match `[A-Z][A-Z0-9]+-\d+`, tell the user it is not a valid ticket key and stop there.

Session tracking only works when the skill is invoked as `/ticket-pilot:start <KEY>`, with the key in uppercase right after the command; if the user started it another way, tell them so.

This file is written in English, but **you write to the user only in the language decided at the start** (see below). Language rule, checked before every message:

- Decide the user's language once, at the start: the language instructions of the user's own instructions (CLAUDE.md, memory) win; otherwise the language of the user's messages. Keep it for the whole run.
- Every sentence the user sees is in that language and register (if the user says "tu", say "tu"): one-line progress narration between tool calls, questions, summaries, tables, the test plan and the final report. No English sentence, not even a short "Checking the build".
- Agent and tool outputs often come back in English: translate what you show, never paste or echo their English.
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

**The config.** Read the config file with the Read tool: `$TICKET_PILOT_CONFIG` when set, else `~/.config/ticket-pilot/config.json`. In the steps below, "the repo entry" is the entry of `repos` chosen at start-up. Optional keys, used when present: on the repo entry `setup_command`, `sync_command`, `launch_skill`, `ci_review_prompt` (a path relative to the repo root), `ci_review_command`; at the top level `sync_command`, `reviewer_agent`, `auditor_agent`, `backend.repos`, `backend.api_docs`, `max_commit_lines`.

**The user's memory for this repo.** Claude Code loads the user's memory only for the directory the session started in: a session started in the worktree or in another directory does not see the memory of the repo, and a loaded index is not a rule applied. So read it yourself, at start-up and on resume: the folder is `~/.claude/projects/<name>/memory/`, where `<name>` is the main repo root with every non-alphanumeric character replaced by `-` (for example `/home/a.b/dev/app` gives `-home-a-b-dev-app`). Read its `MEMORY.md` and every file it links about code, naming, vocabulary, tests or commits. No such folder → say so once and carry on. Go over these rules again before naming anything (the branch in step 2, every symbol in step 5, every commit subject in step 9) and before splitting the commits: a rule of the memory wins over a default of this skill, for example the order or the grouping of the split.

**The worktree.** Bash `cd` outside the session's working directory may not persist between calls. Every command for the worktree is either `cd "<worktree>" && …` in the same call or `git -C "<worktree>" …`. Every file edit uses an absolute path inside the worktree. Never edit the main checkout.

**Questions.** Ask only for decisions that change what gets built: a real divergence between sources, a real ambiguity, a conflict between the design and the ticket. One question at a time, always with your recommendation. Every question to the user (the go, a divergence, a branch reference, launching the app, any choice) is recorded first with `"<plugin-root>/bin/tp" run-wait <id> <kind> "<the question text, in the user's language>"`, the text of the question itself, never an empty text; the steps below repeat it where it applies. Then wait for the answer.

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

1. Read the whole ticket with the Atlassian MCP tools. Fallback: the Jira REST API with the config's `jira.site` and `jira.email`, and the token from the Keychain entry `jira.keychain_service` (`security find-generic-password -s "<service>" -w`). Never print the token.
   - description and acceptance criteria;
   - **every comment**: a late comment often changes the scope ("in the end we do X");
   - attachments, linked tickets, the parent epic.
2. Read **every** Confluence page linked from the ticket, images included, every Figma link, and every linked Slack thread. If a source cannot be read (missing tool, no access), list it as unread; never guess its content.
3. Write the **numbered list of requests**: one request per number, each with its source (ticket description, comment, Confluence page, Figma frame…). Record it, in order, one flag per request: `"<plugin-root>/bin/tp" run-set <id> --request "<1. request — source>" --request "<2. …>"`. Record it again whenever the list changes (an answer of the user, a resume).
4. Present to the user: a short summary, the numbered requests, the target repo, and the ambiguous points.
5. Ask in the same message, in the user's language, whether to add the line `JIRA: <KEY>` to the commits. The line is never added without a yes.
6. Record the wait, then wait: `"<plugin-root>/bin/tp" run-wait <id> go "<in the user's language: one-line summary + the question about the JIRA line>"`. This go is the only systematic validation of the run. Nothing else starts before it.
7. On the go, record the answer: `"<plugin-root>/bin/tp" run-set <id> --jira-line yes` or `--jira-line no`.

## Step 2 — Prepare

Run `"<plugin-root>/bin/tp" run-step <id> 2`.

1. Sync the main repo: run `sync_command` (repo entry first, then top level) from the main repo root. Without one: `git -C "<repo>" fetch origin`.
2. Choose a branch name: a short descriptive slug of the change, in kebab-case, **without the ticket number** (for example `show-delivery-distance`). Name the feature with the term the code already uses for it (an existing toggle, type or field name, found with `git -C "<repo>" grep -i "<term>" origin/<main_branch>`), not with a synonym from the ticket that appears nowhere in the code.
3. Create a dedicated worktree at `<repo-path>-worktrees/<slug>` (sibling of the repo; avoid spaces in the path), always from the up-to-date remote main branch: `git -C "<repo>" worktree add --no-track -b <slug> "<worktree>" origin/<main_branch>`.
   - If that path or branch already exists and belongs to this run (the run's recorded `branch` is `<slug>`, or the path equals the run's recorded `worktree`), reuse it: do not create it again.
   - If it belongs to something else, never touch it: propose another slug as a question, `"<plugin-root>/bin/tp" run-wait <id> question "<in the user's language: slug X is taken, use slug Y? + recommendation>"`, and wait for the answer.
4. Note the base commit: `git -C "<worktree>" merge-base HEAD origin/<main_branch>`. It is `<base>` in every later step.
5. Record it: `"<plugin-root>/bin/tp" run-set <id> --worktree "<worktree>" --branch <slug>`.
6. Set up the worktree: `cd "<worktree>" && <setup_command>`, or the repo's own build skill when it handles project generation itself.
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
5. **The target module's architecture**: the module's own architectural choice is the reference, not only the neighbouring file. **When in doubt, look at the whole codebase.**
6. **Local work in progress**: in the target repo and in the other platform repos, someone (often the user) may already have an unpushed local branch on this ticket. For each repo:
   - list the local branches with their last commit date: `git -C "<repo>" for-each-ref refs/heads --sort=-committerdate --format='%(refname:short) %(committerdate:short) %(subject)'`;
   - match the branch names of that list against the ticket key and the topic keywords;
   - search the unmerged commits of every local branch by message, for the ticket key, the feature toggle name and the topic keywords: `git -C "<repo>" log --branches --not origin/<main_branch> --source -i --grep "<term>"` (`--source` prints the branch each commit was reached from);
   - search each branch's own changes, never its whole content (a term already on the main branch would match every branch): `git -C "<repo>" log origin/<main_branch>..<branch> -i -G "<term>" --oneline` and `git -C "<repo>" diff origin/<main_branch>...<branch> | grep -i "<term>"`;
   - a feature toggle that exists on the main branch but that nothing reads is a strong clue that the work exists elsewhere: look for the branch whose own changes read it.
   A candidate branch is a local branch whose name matches, or whose own commits match by message (`-i --grep`) or by change (`-G`). Exclude the run's own branch (`<slug>`, created in step 2). Unmerged local work is reported as local, not as merged: merged code is only what item 2 reads from `origin/<main_branch>`.

If an agent finds no implementation on a platform, rerun the sync for that repo yourself (its `sync_command`, else `git -C "<repo>" fetch origin`), then search `origin/<main_branch>` again before concluding "not started".

If item 6 finds a candidate branch, record it and ask ONE question, with your recommendation: `"<plugin-root>/bin/tp" run-wait <id> question "<in the user's language: is branch X (repo, last commit date) the reference for this ticket? + recommendation, yes or no and why>"`, then wait for the answer. If yes, that branch is the **primary reference**: compare against it in step 4 and reuse its logic and design rather than re-inventing them.

## Step 4 — Compare and decide

Run `"<plugin-root>/bin/tp" run-step <id> 4`.

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

- Follow the repo's instructions (`CLAUDE.md`, `AGENTS.md`, linked docs), the user's memory for this repo, and the module's architecture.
- **New behaviour behind a feature toggle**, following the repo's toggle conventions. With the toggle OFF, the current production behaviour stays exactly the same. Exception: when the ticket itself is the clean-up of a toggle, no new toggle is created; the clean-up keeps the toggle-ON behaviour and removes the toggle and its OFF path.
- Simple but professional code, senior level: no duplication, no needless extension or helper, no superfluous abstraction.
- Do not touch any module owned by another team (check the repo's ownership files or instructions; ask when unsure).
- Tests following the repo's and the user's conventions, with realistic values.
- Nothing from "Failures, even if it works": no unrequested change, no extra comment, no removed comment or TODO, no stray file.

## Step 6 — Verify

Run `"<plugin-root>/bin/tp" run-step <id> 6`.

1. **Build** with the repo's build command or build skill.
2. **Tests**: run them and make them pass.
3. **Snapshots**: only those of the impacted views, regenerated, and kept in the same commit as the change they reflect.
4. **Test necessity**:
   - every added test is useful;
   - no dedicated test for a single value when an existing test can take one more line;
   - no test for an impossible scenario;
   - existing tests are not renamed.
5. **Toggle OFF = production**: prove, by reading the diff (`git -C "<worktree>" diff <base>`) and by the tests, that with the toggle OFF no behaviour changes. Quote the lines that prove it.

## Step 7 — Test in the app

Run `"<plugin-root>/bin/tp" run-step <id> 7`.

This step is "not applicable" only when the change has no effect visible in the app, and the reason must cite the diff that shows it (for example "only `path:line` of the build scripts changes").

For the whole step: once the app runs on a device, simulator or browser that the user launched (or said is ready), never install, reinstall, rebuild or relaunch it there without an explicit yes for that exact action. A short or ambiguous reply ("ok", "done") to a question that offered several actions means ready, not permission to act. When in doubt, ask again in one sentence.

1. Try to build and launch the app (simulator, emulator or browser) with the repo entry's `launch_skill`, or the repo's own launch skill if it has one.
2. If that fails, or if there is no such skill, do not tinker: never write your own tooling to drive the app, and never ask the user to grant system permissions (accessibility, screen recording…) to make one work. When nothing available can drive the app, give the user the numbered cases of the test plan to run, with what to look at, record the wait with `"<plugin-root>/bin/tp" run-wait <id> question "<in the user's language: the cases to run and what to report>"`, and fill the results from their answers and screenshots. Ask the user to launch the app, with the toggle state you need, and wait: `"<plugin-root>/bin/tp" run-wait <id> launch_app "<in the user's language: what to launch and with which toggle state>"`.
   - Toggles: never edit generated or shipped config files to flip a toggle. Ask the user to set it in the app's debug menu.
3. **Proxy state**, before running the cases, when a debugging proxy is in use: list the proxy's active rules (rewrite, scripting, breakpoint, map rules). Report every rule that alters requests or responses; before disabling one, ask with `"<plugin-root>/bin/tp" run-wait <id> question "<in the user's language: may I disable rule X, which alters Y? + recommendation>"` and wait for the answer. Never leave a rule you enabled active. The test plan states that real (unaltered) traffic was used, or which rule altered it.
4. Once the app runs, drive it:
   - validation scenarios for each request;
   - edge cases;
   - **toggle ON, then OFF** (non-regression);
   - network calls checked in the proxy when needed.
5. Write the **test plan in QA format** and record each result ✅ / ❌ / ❓, following `references/test-plan-format.md`: prerequisites, numbered and titled cases (one per request, one per branch added in the diff, real data, "Proxy:" checks), complementary checks (toggle OFF identical to production, out-of-scope cases unchanged) and open questions. The plan has no code references (no file paths, `path:line`, code names or endpoint paths): it is written in plain functional language, with the case ↔ request link as "(Request N)".
6. The plan and its results go into the final report, ready to be pasted as is into a Jira comment by the user. The traceability to the code goes in a separate **Coverage** list of the report: one line per case, case title → request number and/or diff branch (`path:line`).

## Step 8 — Review and audit

Run `"<plugin-root>/bin/tp" run-step <id> 8`.

Make new files visible to the diff first: `git -C "<worktree>" add --intent-to-add <new files>`. The full diff is `git -C "<worktree>" diff <base>`.

1. **Reviewer** on the full diff: agent type `reviewer_agent` from the config, else `ticket-pilot:reviewer`. Give it:
   - the diff (paste it, or for a large one the exact read-only command that prints it, and say it is the whole change);
   - the worktree path;
   - when the repo entry has `ci_review_prompt`: its absolute path (main repo root + the configured relative path).

   The reviewer only applies the CI prompt: it is not the CI review itself, which also builds its own context and output. The CI review is replayed in step 9, on each commit, when the repo entry has `ci_review_command`.
2. Read its answer: line 1 `Score: …`, line 2 the reason. A reason starting with `INPUT MISSING:` is a failure to fix (give the missing input and rerun), never a pass. Every remark, whatever the score, comes as `path:line → problem`; a reason that mentions a remark without listing it is incomplete: ask the reviewer for the lines before going on.
3. **Auditor**, with a fresh context: agent type `auditor_agent` from the config, else `ticket-pilot:auditor`. Give it ONLY the full diff, the numbered list of requests and the worktree path. No reasoning, no justification.
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

Then run `"<plugin-root>/bin/tp" run-done <id>`.

End the report with the command the user runs to send the branch, chosen by the repo entry's `review`, printed for the user only (do not run it):

- `review` is `gerrit` → `cd "<worktree>" && git review` (print it, do not run it);
- `review` is `github` → `cd "<worktree>" && git push -u origin <branch>` then `gh pr create` (print them, do not run them).

## After the report

The user often reacts to the report: a naming, a test result to correct, a line to remove. A remark that only corrects the report (a wording of the test plan, a ❓ the user answers) → fix the report, nothing else. A remark that changes the code or the commits reopens the run; never patch it outside the steps:

1. Run `"<plugin-root>/bin/tp" run-step <id> 5`: the run is no longer `done`. Make the change on the branch.
2. Step 6 again (build, tests, toggle OFF).
3. Step 7 again only if what the user sees in the app changes; otherwise start it with `run-step` and check it as not applicable, citing the diff.
4. Step 8 again, **reviewer and auditor** on the new full diff: a rename or a removal can leave dead code or a name that no longer fits.
5. Step 9 again: each change as a fixup into the commit it belongs to, the whole chain verified, the reviewer on every rewritten commit.
6. Step 10 again: what changed since the last report, then `"<plugin-root>/bin/tp" run-done <id>`.

## Resume

The run state lives in the ticket-pilot state directory (`runs/<id>.json`): current step, worktree, branch, `jira_line`. When the user accepts to resume an unfinished run:

1. Read it with `"<plugin-root>/bin/tp" run-show <id>`. Check that the worktree and branch still exist only if they are recorded (a run stopped at step 1 or 2 may have none yet). If a recorded one is gone, tell the user and stop.
2. Recreate the checklist when the task tool is available: steps before `step` are done (from `history`), the others are pending.
3. If a worktree is recorded and the run resumes at step 3 or later, recompute `<base>` exactly as in step 2 point 4: `git -C "<worktree>" merge-base HEAD origin/<main_branch>`. Every later step uses this value.
4. Read the ticket again and rebuild the numbered list of requests (step 1 points 1 to 3), then compare it with the recorded `requests`: keep the recorded numbering for the requests that did not change, so that the test plan and the coverage still match. Ask for the go again only if the ticket changed in a way that changes the requests, or if the run stopped at step 1 before the go; keep the recorded `jira_line`.
5. Tell the user you resume step `step` from its beginning, then restart it with `run-step` and carry on from there. A pending question of that step is asked again as the step reaches it.
