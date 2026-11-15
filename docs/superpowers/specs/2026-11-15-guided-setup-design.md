# Guided setup: no config file to write

## Why

A colleague must be able to install ticket-pilot alone, from the release zip, without help and without
ever opening `config.json`. Today, after "Create your config" (branch `newcomer-setup`), they get the
example file in TextEdit: JSON, twenty keys, most of them advanced, and a required key
(`jira.keychain_service`) that is useless to choose: it is removed. The owner tried it and found
it too hard and not intuitive.

## Goals

- From a fresh Mac to a working panel with only clicks and, at most, confirming a proposed name.
- The app writes the config itself. The file stays the place for advanced options, but no one needs to
  open it to start.
- Repositories can be added and removed later, in Settings.

## Non-goals

- No editor in the app for the advanced keys (`setup_command`, `env`, `ci_review_*`, `launch_skill`,
  `editor`, `guidelines`, `stuck_minutes`…). They stay in the file.
- No first-launch wizard window (approach B, rejected).
- No terminal step (`tp init`, rejected).

## Anti-goals

- Asking for something the app can find itself (site, email, main branch, review kind).
- Losing what a user wrote in the file by hand: every edit keeps the other keys (as `ConfigEditor`
  already does for `terminal_app` and `jira.auth`).
- A config that the app accepts but the skill's `tp config-check` refuses (both sides must agree).

## Approaches

- **A. The panel's setup banner guides step by step, repositories are managed in Settings.** Chosen. It
  reuses the banner (`SetupProblem`), Settings and `ConfigEditor`.
- B. A first-launch wizard window. Rejected: one more UI used once, and Settings still needs a repository
  list for later changes.
- C. An interactive `tp init` in the terminal. Rejected: it sends people to a terminal, which the app
  exists to avoid.

## The flow (decided)

The banner's steps, in this order:

1. "Install Claude Code…" (unchanged).
2. "Install the Claude Code plugin…" (unchanged).
3. "Connect Jira…": the Atlassian sign-in, which needs no config. When it comes back, the app reads the
   account's email (`atlassianUserInfo`) and its sites (`getAccessibleAtlassianResources`). One site: it is
   used. Several: the app asks which one (a dialog listing their URLs). The app then writes `jira.site`
   and `jira.email`, creating the config file when there is none (`{"jira": {...}, "repos": []}`).
4. "Add a repository…": the Finder folder picker. The app checks that the folder is a git checkout, then
   proposes, in one dialog the user confirms or corrects:
   - the name/platform: from the project type (an `.xcodeproj`, `.xcworkspace` or `Package.swift` → `ios`;
     Gradle → `android`; `package.json` → `web`; else the folder name), editable;
   - the main branch: `origin/HEAD` (`git symbolic-ref --short refs/remotes/origin/HEAD`, without
     `origin/`); else `main` or `master`, whichever exists;
   - the review kind: `gerrit` when the `origin` URL uses port 29418, `github` when its host contains
     `github` or ends in `.ghe.com`; else the user picks one of the two;
   - the match rules, from the platform: `ios` → title prefix `[iOS]`, label and component `iOS`;
     `android` → `[Android]`, `[AND]`, `Android`; `web` → `[Web]`, `Web`; other names → `[<name>]`, `<name>`.
   The dialog shows the name, the platform's display name, the main branch and the review kind; the match
   rules are written without being shown.
5. Then the usual checks (Jira reachable, repo paths…).

The banner stays on step 4 while `repos` is empty.

"Create your config", "Edit your config" (example detection) and the copied example, from the
`newcomer-setup` branch, are replaced by steps 3 and 4. "Fix the config…" stays for a file that does not
load.

## Settings (decided)

A "Repositories" section: one row per repo ("iOS · ~/Developer/app · master · gerrit") with a remove
button (asks first; it removes the entry from the config, never the folder), and "Add a repository…"
(the same flow as step 4).

## Config changes (decided)

- `jira.keychain_service` is removed: the Keychain entry of the Jira API token is always
  `ticket-pilot-jira` (only used with `jira.auth` `api_token` and as the skill's REST fallback). An old
  config that still has the key loads and the key is ignored. Changed in the app (`AppConfig`), the skill
  (`skills/start/SKILL.md`), `config.example.json` and the README. It is only used with `jira.auth` `api_token` and as the
  skill's fallback.
- `config.example.json` stays, as a reference for the advanced keys; the app no longer copies it.

## Calls made after the builder check (the owner can override)

- **Setup states.** `ConfigProblem` becomes: `missing` (no file: step 3), `invalid` (unchanged), `noRepos`
  (`repos` empty: step 4). The example detection goes. Without a config the doctor runs the checks that
  need none (as on `newcomer-setup`). The Atlassian sign-in needs no config (checked in the code).
- **Step 3 with a file already there, or a sign-in already stored** (reinstall): the app fills only what
  is missing (`jira.site`, `jira.email`), never overwrites a value written by hand. With a stored sign-in
  and no file, step 3 reads the account at once, with no browser.
- **Sites.** Only resources whose scopes include Jira are listed. None: the banner explains that the
  account has no Jira site.
- **One name field.** The dialog has one editable name, proposed from the platform (`ios`, `android`,
  `web`) or the folder name made valid (`[A-Za-z0-9._-]`, spaces as `-`). The match rules come from the
  detected platform, or from the name when there is none. The confirm button stays disabled, with the
  reason, for an empty, invalid or already used name; a folder already in the config is refused with a
  message.
- **Removing a repo with runs.** Refused while a run of that repo exists ("Remove its worktrees
  first"), so no card loses its repo.
- **The skill side.** `tp config-check` does not validate the `jira` block today, so no Python change
  is needed: only `AppConfig`, the README, `config.example.json` and `skills/start/SKILL.md` (the REST
  fallback always reads the Keychain entry `ticket-pilot-jira`).

## Left to the builder

- Exact wording of the dialogs and the banner lines (short, in the tone of the existing ones).
- How the site choice dialog is built (an `NSAlert` with a pop-up is enough).
- The `ConfigEditor` functions needed (set the Jira site and email, add and remove a repo) and how a
  missing file is created.
- Tests: the detection rules (platform, main branch, review kind, match rules) and the config edits are
  in `TicketPilotCore` and get unit tests; the dialogs are checked by running the app.
- Keeping the newcomer simulation working (`CFFIXED_USER_HOME`, `TICKET_PILOT_DEBUG_*`) to replay the flow
  from an empty home before shipping.
