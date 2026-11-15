# Guided setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A colleague goes from the release zip to a working panel with clicks only: the app writes the config (Jira site and email from the Atlassian sign-in, repositories from a folder picker).

**Architecture:** Detection and config edits live in `TicketPilotCore` (unit-tested); `AppModel`, `Alerts` and `SettingsView` in the `TicketPilot` target wire them to the setup banner and Settings. The setup banner keeps its order (`SetupProblem.first`), with new config states.

**Tech Stack:** Swift 6, SwiftUI/AppKit, Swift Testing (`swift test` in `app/`), Python plugin (`python3 -m unittest discover -s tests`).

**Spec:** `docs/superpowers/specs/2026-11-15-guided-setup-design.md`

## Global Constraints

- Every config edit keeps the other keys and their spelling (`ConfigEditor`); a symlinked config is edited where it points (`AppModel.editConfig`).
- `review` is `gerrit` or `github` only (`ticket_pilot/config.py` `REVIEW_KINDS`); a repo name matches `[A-Za-z0-9._-]+` and is unique.
- The Keychain entry of the Jira API token is always `ticket-pilot-jira`; `jira.keychain_service` in an old config is ignored.
- Branch `newcomer-setup`, nothing pushed. Commits fold into `72d093e feat(app): guide a first launch…` with `git commit --fixup=72d093e` (it is not pushed); the message is reworded at the end (Task 7).
- Copy in the tone of the existing banner: short, sentence case, an ellipsis on a button that opens a dialog.

## Review Focus

- A folder that is not a git checkout: refused with "This folder is not a git repository." (Task 4 test).
- No `origin` remote, or one that is neither Gerrit nor GitHub: the dialog asks for the review kind instead of guessing (Task 4 test: `review == nil`).
- No `origin/HEAD`: `main` or `master`, whichever exists; neither → `nil`, and the dialog's main branch field is then empty and required (Task 4 test).
- An Atlassian account with no Jira site: the banner says so instead of writing a config (Task 2 test: `sites.isEmpty`).
- A config written by hand before: step 3 fills only the missing `site`/`email`, never overwrites (Task 3 test).

---

### Task 1: Remove `jira.keychain_service`

**Files:**
- Modify: `app/Sources/TicketPilotCore/AppConfig.swift` (`JiraSettings`), `app/Sources/TicketPilotCore/Doctor.swift:299`, `app/Sources/TicketPilot/AppModel.swift:203,1193`
- Modify: `skills/start/SKILL.md:80`, `config.example.json`, `README.md` (lines 116-119, 138-139)
- Test: `app/Tests/TicketPilotCoreTests/AppConfigTests.swift`

**Interfaces:**
- Produces: `JiraSettings.tokenKeychainService: String` (static, `"ticket-pilot-jira"`), replacing the instance property `keychainService`.

- [ ] **Step 1: Write the failing test** `test_keychainServiceIsNoLongerNeeded`: a config `{"jira":{"site":"https://acme.atlassian.net","email":"a@b.c"},"repos":[]}` loads; one that still has `"keychain_service":"old"` loads too; `#expect(JiraSettings.tokenKeychainService == "ticket-pilot-jira")`. Remove the `config.jira.keychainService` expectation of `test_decodesExampleConfig`.
- [ ] **Step 2: Run** `cd app && swift test --filter AppConfigTests` → FAIL (missing key / unknown member).
- [ ] **Step 3: Implement**: drop the stored property and its coding key, add the static constant, use it in `Doctor` and `AppModel`. Remove `keychain_service` from `config.example.json` and from the test fixtures that write it (Doctor, ConfigEditor, AppConfig tests) only where it no longer matters. `SKILL.md`: "the token from the Keychain entry `ticket-pilot-jira`". README: the `security add-generic-password … -s "ticket-pilot-jira"` line stays, the sentence names the entry instead of the key; delete the `jira.keychain_service` table row; the `jira.auth` row says "the token of the Keychain entry `ticket-pilot-jira`".
- [ ] **Step 4: Run** `swift test` and `python3 -m unittest discover -s tests` → all pass.
- [ ] **Step 5: Commit** with the spec and this plan: `git add -A docs app skills config.example.json README.md && git commit --fixup=72d093e`.

### Task 2: Read the account's email and Jira sites

**Files:**
- Modify: `app/Sources/TicketPilotCore/MCPJiraClient.swift`
- Test: `app/Tests/TicketPilotCoreTests/MCPJiraClientTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct AtlassianAccount: Equatable, Sendable { public var email: String?; public var sites: [URL] }
  extension MCPJiraClient {
      public static func account(tools: MCPToolCalling) async throws(JiraError) -> AtlassianAccount
  }
  ```
  `sites`: the `url` of each resource of `getAccessibleAtlassianResources` whose `scopes` contain a scope with `jira`, in the server's order, no duplicates. Reuse the resource parsing of `resolveCloudID` (extract it to a static helper) and the `atlassianUserInfo` reading of `accountEmail`, through the same allowed-tools guard.

- [ ] **Step 1: Failing tests** with `FakeTools`: `test_accountListsItsJiraSites` (fixture `MCPJiraFixtures.resources` plus a resource with `"scopes":["read:confluence-content.all"]`) → `sites` holds only the two Jira URLs and `email` is the fixture's; `test_accountWithoutJiraHasNoSites` → `sites.isEmpty`.
- [ ] **Step 2: Run** `swift test --filter MCPJiraClientTests` → FAIL.
- [ ] **Step 3: Implement** `account(tools:)`.
- [ ] **Step 4: Run** → PASS, whole suite passes.
- [ ] **Step 5: Commit** `git commit --fixup=72d093e`.

### Task 3: Config edits: Jira identity, add and remove a repo

**Files:**
- Modify: `app/Sources/TicketPilotCore/ConfigEditor.swift`
- Test: `app/Tests/TicketPilotCoreTests/ConfigEditorTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct RepoEntry: Equatable, Sendable {
      public var name, path, mainBranch, review: String
      public var titlePrefixes, labels, components: [String]
  }
  extension ConfigEditor {
      /// nil data: a new config `{"jira": {"site", "email"}, "repos": []}`. Else sets only the missing keys.
      public static func fillJira(site: URL, email: String?, in data: Data?) throws(ConfigEditError) -> Data
      /// Appends `{"name","path","main_branch","review","match":{"title_prefixes","labels","components"}}` to `repos`
      /// (created when absent).
      public static func addRepo(_ repo: RepoEntry, in data: Data) throws(ConfigEditError) -> Data
      /// Removes the entries of `repos` named `name`.
      public static func removeRepo(named name: String, in data: Data) throws(ConfigEditError) -> Data
  }
  ```
  Strings are JSON-encoded with `JSONEncoder` as `setJiraAuth` does; a nil `email` writes no `email` key.

- [ ] **Step 1: Failing tests**: `test_fillJiraCreatesAConfig` (nil data → decodes with `AppConfig`, `repos == []`, site and email set); `test_fillJiraKeepsWhatIsWritten` (a file with `site` `https://mine.atlassian.net` and `"poll_minutes": 2` → site unchanged, `email` added, `poll_minutes` kept); `test_addRepoAppendsAnEntryAppConfigReads` (decodes: name, path, `mainBranch`, `review`, `match.titlePrefixes == ["[iOS]"]`, other repos kept in order); `test_removeRepoKeepsTheOthers`.
- [ ] **Step 2: Run** `swift test --filter ConfigEditorTests` → FAIL.
- [ ] **Step 3: Implement** the three functions on the existing `Parser`/`render`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit --fixup=72d093e`.

### Task 4: Detect a repository from its folder

**Files:**
- Create: `app/Sources/TicketPilotCore/RepoDetector.swift`
- Test: `app/Tests/TicketPilotCoreTests/RepoDetectorTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum RepoDetectionError: Error, Equatable { case notAGitRepository }
  public struct RepoProposal: Equatable, Sendable {
      public var name: String          // "ios", "android", "web", else the folder name made valid
      public var path: String
      public var mainBranch: String?   // nil: the dialog asks
      public var review: String?       // "gerrit" | "github" | nil: the dialog asks
      public func entry(name: String, mainBranch: String, review: String) -> RepoEntry  // match rules below
  }
  public enum RepoDetector {
      public static func detect(folder: URL, runner: ProcessRunning) throws(RepoDetectionError) -> RepoProposal
      /// nil when valid, else the reason shown under the field.
      public static func problem(withName name: String, existing: [String]) -> String?
  }
  ```
  Rules (spec): platform from the top-level entries (`.xcodeproj`, `.xcworkspace`, `Package.swift` → `ios`; `build.gradle`, `build.gradle.kts`, `settings.gradle(.kts)` → `android`; `package.json` → `web`); folder name made valid: spaces → `-`, other invalid characters dropped. Main branch: `git symbolic-ref --short refs/remotes/origin/HEAD` minus `origin/`, else `main` then `master` if `refs/heads/` or `refs/remotes/origin/` has it. Review: `origin` URL with `:29418` → `gerrit`; host containing `github` or ending in `.ghe.com` → `github`. Match rules in `entry`: from `name` when it is `ios` (`["[iOS]"]`, `["iOS"]`, `["iOS"]`), `android` (`["[Android]", "[AND]"]`, `["Android"]`, `["Android"]`), `web` (`["[Web]"]`, `["Web"]`, `["Web"]`), else `["[<name>]"]`, `[name]`, `[name]`. `problem`: empty → "Enter a name.", invalid → "Use letters, digits, ., _ or - only.", taken → "A repository is already named \(name).". Not a git checkout: `git -C <folder> rev-parse --show-toplevel` fails.

- [ ] **Step 1: Failing tests** on temp repos (`SystemProcessRunner`, as `ReleaserTests` does): `test_detectsAnIOSGerritRepo` (an `App.xcodeproj` folder, `origin` `ssh://me@review.example.com:29418/ios/app`, `origin/HEAD` → `master`) → `name == "ios"`, `review == "gerrit"`, `mainBranch == "master"`; `test_detectsAWebGitHubEnterpriseRepo` (`package.json`, `git@acme.ghe.com:org/web.git`) → `web`, `github`; `test_unknownRemoteAndNoOriginHEADLeaveTheChoice` (no remote, only `main`) → `review == nil`, `mainBranch == "main"`; `test_noMainBranchFound` (branch `trunk` only) → `mainBranch == nil`; `test_folderNameMadeValid` (`My App`, no project file) → `"My-App"`; `test_notAGitRepositoryIsRefused`; `test_matchRulesFollowTheName`; `test_nameProblems` (the three messages, nil for a free valid name).
- [ ] **Step 2: Run** `swift test --filter RepoDetectorTests` → FAIL.
- [ ] **Step 3: Implement** `RepoDetector.swift`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit --fixup=72d093e`.

### Task 5: Setup states and the banner

**Files:**
- Modify: `app/Sources/TicketPilotCore/SetupProblem.swift`, `app/Sources/TicketPilotCore/AppConfig.swift` (drop `isExample`, `exampleSiteHost`)
- Test: `app/Tests/TicketPilotCoreTests/SetupProblemTests.swift`, `AppConfigTests.swift` (drop the example tests)

**Interfaces:**
- Produces: `SetupProblem.ConfigProblem` = `.missing`, `.invalid(String)`, `.noRepos`; `SetupProblem.Action` loses `.createConfig`, `.openConfig`, gains `.addRepository`; new case `.noJiraSite` problem built by `SetupProblem.noJiraSite` (static let) for Task 6.
- Order in `first(in:config:jiraFailing:)`: Claude Code, plugin missing, `.missing` → `SetupProblem(title: "Connect Jira…", explanation: "Connect Jira to get started.", action: .connectAtlassian)`, `.invalid` → unchanged "Fix the config…", Jira checks (token, sign-in, unreachable), `.noRepos` → `SetupProblem(title: "Add a repository…", explanation: "Add the repository you work in.", action: .addRepository)`, missing repo path, outdated plugin. `noJiraSite`: title "See why…", explanation "This Atlassian account has no Jira site.", action `.explain(AlertText(title: "No Jira site", message: "The account you signed in with can't open any Jira site. Sign in with your work account: Settings › Jira › Disconnect, then Connect Jira."))`.

- [ ] **Step 1: Failing tests**: replace the create/edit/example tests by `test_missingConfigConnectsJiraFirst`, `test_noReposAsksToAddOneAfterJira` (with `noToken` present → Jira first; without → "Add a repository…"), keep `test_claudeAndThePluginComeBeforeTheConfig` and `test_invalidConfigExplainsWhatIsWrongBeforeJira`.
- [ ] **Step 2: Run** `swift test --filter SetupProblemTests` → FAIL.
- [ ] **Step 3: Implement**.
- [ ] **Step 4: Run** → PASS (the app target will not build until Task 6; run `swift build --target TicketPilotCore`).
- [ ] **Step 5: Commit** `git commit --fixup=72d093e`.

### Task 6: Wire it in the app: Jira identity, Add a repository, Settings

**Files:**
- Modify: `app/Sources/TicketPilot/AppModel.swift`, `app/Sources/TicketPilot/Alerts.swift`, `app/Sources/TicketPilot/SettingsView.swift`, `README.md`

**Interfaces:**
- Consumes: `MCPJiraClient.account(tools:)`, `ConfigEditor.fillJira/addRepo/removeRepo`, `RepoDetector`, `SetupProblem.ConfigProblem`, `.addRepository`, `SetupProblem.noJiraSite`.
- Produces (in `AppModel`): `func addRepository()`, `func removeRepository(named: String)`, `private func completeJiraSetup()`, `private(set) var noJiraSite: Bool`; `configProblem` set to `.noRepos` when the loaded config has no repo; `setupProblem` returns `SetupProblem.noJiraSite` when `noJiraSite` (before the Jira checks).
- `Alerts.chooseSite(_ sites: [URL]) -> URL?` (an alert with a pop-up, "Choose your Jira site", buttons "Use this site"/"Cancel"); `Alerts.confirmRepository(_ proposal: RepoProposal, existing: [String]) -> RepoEntry?` (accessory view: Name field, platform display `RepoName.display`, Main branch field, Review pop-up Gerrit/GitHub preselected when known; "Add" disabled with the `RepoDetector.problem` text, or "Enter the main branch.", or "Choose how changes are reviewed.").

- [ ] **Step 1:** `completeJiraSetup()`: after `connectAtlassian` succeeds, and in `runDoctor` when `configProblem == .missing` and a sign-in is stored, read `MCPJiraClient.account(tools: MCPClient(url: auth.server, tokens: auth, clientVersion: Self.version))`; no site → `noJiraSite = true`; one → it; several → `Alerts.chooseSite` (cancel: nothing written); then write `ConfigEditor.fillJira` (nil data when the file is missing; create the folder), `runDoctor()`. Remove `createConfig()` and the `.createConfig`/`.openConfig` cases; `fixSetupProblem` handles `.addRepository`. `runDoctor`'s no-config guard blocks only `.missing` and `.invalid`. `panelOpened` keeps reloading while `configProblem != nil`.
- [ ] **Step 2:** `addRepository()`: `NSOpenPanel` (folders only, "Add"), `RepoDetector.detect` off the main actor (`untimedRunner`), `.notAGitRepository` → `Alerts.show(AlertText(title: "Not a repository", message: "This folder is not a git repository."))`; a path already in `config.repos` → `Alerts.show` "This repository is already added."; then `Alerts.confirmRepository`, `editConfig { try ConfigEditor.addRepo(entry, in: $0) }`, `runDoctor()`.
- [ ] **Step 3:** `removeRepository(named:)`: refused when `runs` has a run of that repo (`Alerts.show(AlertText(title: "\(display) has runs", message: "Remove its worktrees first."))`); else `Alerts.confirm(…, button: "Remove")` saying the folder stays on disk, `ConfigEditor.removeRepo`, `runDoctor()`.
- [ ] **Step 4:** Settings: a "Repositories" section after "Config": one row per repo, "<Display> · <~path> · <main branch> · <review>", a remove button (`minus.circle`, accessibility label "Remove <Display>"), and "Add a repository…". README: Quick start step 2 becomes "In the app, choose "Connect Jira →", then "Add a repository →" and pick your checkout"; the banner list replaces "Create your config…/Edit your config…" with "Connect Jira…" (first, with no config: fills `jira.site` and `jira.email`, asks which site when the account has several) and "Add a repository…" (folder picker, detection rules, confirmation); Settings section documented; Configure section says the app writes these keys and the file is for the advanced ones.
- [ ] **Step 5: Run** `swift build` and `swift test` → pass.
- [ ] **Step 6: Commit** `git commit --fixup=72d093e`.

### Task 7: Replay a first install, fold the commits

- [ ] **Step 1:** Newcomer simulation (build with `./build-app.sh /tmp/tp-newcomer/TicketPilot.app`, launch with `HOME` and `CFFIXED_USER_HOME` on an empty folder that only links `~/.local/bin/claude`, `TICKET_PILOT_DEBUG_OPEN_PANEL=1`): the banner reads "Install the Claude Code plugin →", then "Connect Jira →". The sign-in and the folder picker are then done by the owner in the real app (Step 3).
- [ ] **Step 2:** `git rebase -i --autosquash main` is interactive: use `GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash main`, then `git commit --amend` on the first commit with the message `feat(app): set up from the app, with no config file to write` and a body describing the flow (plugin, Connect Jira fills the site and email, Add a repository detects the rest, Settings › Repositories, `jira.keychain_service` removed), ending with `Co-Authored-By: Claude Code <noreply@anthropic.com>`. Check `git log --oneline main..` shows three commits and `swift test` plus the Python tests pass.
- [ ] **Step 3:** Install the build in `/Applications` (the owner's Mac is in first-install state) and hand over to the owner for the real flow: Connect Jira, Add a repository.
