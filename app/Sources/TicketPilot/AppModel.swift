import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import TicketPilotCore

/// The app state shown in the panel, and every action the panel, Settings or a notification can trigger.
@MainActor @Observable
final class AppModel {
    private(set) var todo = TodoList(issues: [], readyStatuses: [])
    private(set) var runGroups: [RunGroup] = []
    private(set) var iconState: RunIconState = .idle
    /// Also true while there is no valid config or no token: Jira is not read at all.
    private(set) var jiraFailing = false
    private(set) var health: [HealthCheck] = []
    private(set) var releasable: Set<String> = []
    private(set) var configError: String?
    private(set) var openAtLogin = false
    /// Disk usage of each run's worktree, by run id.
    private(set) var diskUsage: [String: Int64] = [:]
    /// The check whose fix command was just copied: it reads "Copied ✓" for a few seconds.
    private(set) var copiedFix: HealthCheck.Kind?
    /// The terminal sessions open in, resolved at launch and on "Check again".
    private(set) var terminalChoice = TerminalChoice(appName: "Terminal")
    /// The terminal picked when `terminal_app` is not set, shown as "Automatic (<name>)" in Settings;
    /// nil while it is being detected.
    private(set) var automaticTerminal: TerminalChoice?
    /// The known terminals found in the application folders.
    private(set) var installedTerminals: [String] = []
    /// `terminal_app` in the config, if set.
    private(set) var configuredTerminal: String?
    /// False until Jira first answered: until then the panel claims nothing about the tickets.
    private(set) var jiraAnswered = false
    private(set) var runs: [Run] = []
    private(set) var acknowledged: Set<String> = []
    /// True from the plugin install's confirmation until its last command has run.
    private(set) var installingPlugin = false

    /// `UNUserNotificationCenter` and `SMAppService` need a `.app` bundle.
    let hasBundle = Bundle.main.bundleIdentifier != nil

    var icon: MenuBarIcon {
        MenuBarIcon.make(iconState: iconState, hasSetupProblem: setupProblem != nil)
    }

    /// The problem the panel offers to fix, if any.
    var setupProblem: SetupProblem? {
        SetupProblem.first(in: health, configError: configError, jiraFailing: jiraFailing)
    }

    /// The setup button: "Copied ✓" for a few seconds once its fix command is copied.
    var setupProblemTitle: String? {
        guard let setupProblem else { return nil }
        if case let .copyFix(check) = setupProblem.action, copiedFix == check.id { return "Copied ✓" }
        return setupProblem.title
    }

    /// The headline under the panel's big mark.
    var status: PanelStatus {
        PanelStatus.make(
            runs: runs,
            acknowledgedDone: acknowledged,
            setupProblem: setupProblem,
            todoCount: jiraAnswered ? todo.ready.count + todo.backlog.count : nil
        )
    }

    /// The terminals Settings offers besides "Automatic".
    var terminalOptions: [String] {
        TerminalChoice.options(installed: installedTerminals, configured: configuredTerminal)
    }

    /// The Settings choice for `terminal_app`: nil for "Automatic".
    var selectedTerminal: String? {
        TerminalChoice.selectedOption(configured: configuredTerminal, in: terminalOptions)
    }

    @ObservationIgnored private let paths = StatePaths()
    @ObservationIgnored private let runner = SystemProcessRunner(timeout: 20)
    @ObservationIgnored private var ghosttyAlertsShown: Set<String> = []
    @ObservationIgnored private var ghosttyBusyRuns: Set<String> = []
    @ObservationIgnored private let ghosttyRunner = SystemProcessRunner(timeout: 300)
    /// `claude plugin marketplace update` may clone a repository: generous, but finite.
    @ObservationIgnored private let pluginRunner = SystemProcessRunner(timeout: 300)
    /// For `git worktree remove` and `du` on a big worktree, which must not be killed midway.
    /// Only used off the main actor.
    @ObservationIgnored private let untimedRunner = SystemProcessRunner()
    @ObservationIgnored private let sleepGuard = SleepGuard()
    @ObservationIgnored private let picker = RepoPickerWindow()
    @ObservationIgnored private let settingsWindow = AuxiliaryWindow()
    @ObservationIgnored private let aboutWindow = AuxiliaryWindow()
    @ObservationIgnored private var config: AppConfig?
    @ObservationIgnored private var poller: JiraPoller?
    @ObservationIgnored private var notifier: Notifier?
    @ObservationIgnored private var watcher: RunWatcher?
    @ObservationIgnored private var issues: [JiraIssue] = []
    @ObservationIgnored private var needsYou = NeedsYouTracker()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var terminalTask: Task<Void, Never>?
    @ObservationIgnored private var doctorTask: Task<Void, Never>?
    @ObservationIgnored private var copiedTask: Task<Void, Never>?
    /// The run version (`updatedAt`) each size was measured for, or is being measured for.
    @ObservationIgnored private var measuredAt: [String: Date] = [:]

    private var acknowledgedStore: SeenStore {
        SeenStore(file: paths.appDirectory.appendingPathComponent("acknowledged.json"))
    }

    // MARK: - Start

    func start() {
        guard watcher == nil else { return }
        if hasBundle {
            notifier = Notifier { [weak self] in self?.handle($0) }
            notifier?.requestAuthorization()
            LoginItem.registerOnce(marker: paths.appDirectory.appendingPathComponent("login-item-registered"))
            openAtLogin = LoginItem.isEnabled
        }
        poller = JiraPoller(seenStore: SeenStore(file: paths.appDirectory.appendingPathComponent("seen.json"))) {
            [weak self] outcome, jira in await self?.apply(outcome, from: jira)
        }
        acknowledged = acknowledgedStore.load() ?? []
        let watcher = RunWatcher(directory: paths.runsDirectory) { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        watcher.start()
        self.watcher = watcher
        refreshRuns()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.updatePresentation()
            }
        }
        runDoctor()
    }

    /// Reloads the config and the Jira token, checks the setup and polls Jira at once.
    func runDoctor() {
        doctorTask?.cancel()
        loadConfig()
        guard let config else {
            poller?.stop()
            jiraFailing = true
            health = []
            return
        }
        let service = config.jira.keychainService
        let runner = runner
        doctorTask = Task { [weak self] in
            let token = await Task.detached {
                Result<String, KeychainError> { () throws(KeychainError) in try Keychain.password(service: service) }
            }.value
            guard !Task.isCancelled, let self else { return }
            let jira = (try? token.get()).map {
                JiraClient(site: config.jira.site, email: config.jira.email, token: $0)
            }
            if let jira {
                poller?.start(jira: jira, pollMinutes: config.pollMinutes)
            } else {
                poller?.stop()
                jiraFailing = true
            }
            let doctor = Doctor(
                config: config,
                home: FileManager.default.homeDirectoryForCurrentUser,
                runner: runner,
                jira: jira,
                tokenLookup: { try token.get() },
                freeBytes: freeBytesOnHomeVolume,
                bundledPluginManifest: Doctor.bundledPluginManifest(resources: Bundle.main.resourceURL)
            )
            let checks = await Task.detached { await doctor.run() }.value
            guard !Task.isCancelled else { return }
            health = checks
        }
    }

    /// The application macOS opens `.command` shell scripts with.
    private nonisolated static func systemShellScriptApp() -> URL? {
        if let type = UTType("com.apple.terminal.shell-script") {
            return NSWorkspace.shared.urlForApplication(toOpen: type)
        }
        let probe = FileManager.default.temporaryDirectory.appendingPathComponent("tp-probe.command")
        return NSWorkspace.shared.urlForApplication(toOpen: probe)
    }

    /// Looks for the terminal off the main actor (`ps` may be slow); the previous choice stays until the
    /// new one arrives, and `afterTerminalResolved` holds back the actions that need it.
    private func resolveTerminal(configured: String?) {
        terminalTask?.cancel()
        automaticTerminal = nil
        let task = Task { [weak self] in
            let (choice, automatic, installed) = await Task.detached {
                () -> (TerminalChoice, TerminalChoice, [String]) in
                let detector = TerminalDetector(runner: SystemProcessRunner(timeout: 5))
                let host = detector.hostOfRunningClaude()
                let installed = detector.installedTerminals()
                let systemDefault = Self.systemShellScriptApp()
                func resolve(_ configured: String?) -> TerminalChoice {
                    TerminalChoice.resolve(
                        configured: configured,
                        hostOfRunningClaude: host,
                        installedTerminals: installed,
                        systemDefault: systemDefault
                    )
                }
                return (resolve(configured), resolve(nil), installed)
            }.value
            guard !Task.isCancelled, let self else { return }
            terminalChoice = choice
            automaticTerminal = automatic
            installedTerminals = installed
            terminalTask = nil
        }
        terminalTask = task
    }

    /// Runs `body` now, or once the terminal detection in flight has finished.
    private func afterTerminalResolved(_ body: @escaping @MainActor () -> Void) {
        guard terminalTask != nil else {
            body()
            return
        }
        Task { [weak self] in
            while let task = self?.terminalTask {
                await task.value
                if self?.terminalTask == task { self?.terminalTask = nil }
            }
            body()
        }
    }

    private func loadConfig() {
        do {
            config = try AppConfig.load(from: paths.configFile)
            configError = nil
            configuredTerminal = config?.terminalApp
            resolveTerminal(configured: config?.terminalApp)
        } catch {
            config = nil
            configuredTerminal = nil
            configError = switch error {
            case let .missing(path): "not found at \(path)"
            case let .invalid(message): message
            }
        }
    }

    // MARK: - Jira

    private func apply(_ outcome: PollOutcome, from jira: JiraClient) async {
        switch outcome {
        case .failed:
            jiraFailing = true
        case let .succeeded(issues, newTickets):
            jiraFailing = false
            jiraAnswered = true
            self.issues = issues
            todo = TodoList(issues: issues, readyStatuses: config?.readyStatuses ?? [])
            newTickets.forEach { notifier?.notifyNewTicket($0) }
            await refreshReleasable(jira)
        }
    }

    /// A failure here only keeps the previous set: it never affects polling or the todo list.
    private func refreshReleasable(_ jira: JiraClient) async {
        let polledRuns = runs
        let keys = Set(polledRuns.map(\.key)).sorted()
        guard !keys.isEmpty, let categories = try? await jira.statusCategories(of: keys) else { return }
        releasable = Releasable.runIDs(runs: polledRuns, categories: categories)
    }

    // MARK: - Runs

    /// The watcher fires several times per write: refresh once things settle.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.refreshRuns()
        }
    }

    private func refreshRuns() {
        runs = RunStore(directory: paths.runsDirectory).loadAll()
        for event in needsYou.events(for: runs) {
            notifier?.notify(event, identifier: event.notificationID(in: runs))
        }
        updatePresentation()
        measureDiskUsage()
    }

    /// Also run every minute, so a run interrupted without a status update stops keeping the Mac awake.
    private func updatePresentation() {
        iconState = RunIconState.make(runs: runs, acknowledgedDone: acknowledged)
        let now = Date()
        let stuckMinutes = config?.stuckMinutes ?? [:]
        runGroups = RunGroup.make(runs: runs, now: now, stuckMinutes: stuckMinutes)
        sleepGuard.update(anyRunning: SleepPolicy.keepsMacAwake(runs: runs, now: now, stuckMinutes: stuckMinutes))
    }

    /// "Show in Finder · <size>" for a run with a worktree.
    func showInFinderTitle(runID: String) -> String? {
        runs.first { $0.id == runID }.flatMap { RunLine.showInFinderTitle($0, bytes: diskUsage[runID]) }
    }

    /// Reveals the run's worktree in the Finder.
    func revealWorktree(runID: String) {
        guard let path = runs.first(where: { $0.id == runID })?.worktree else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Measures the worktree of each finished run off the main actor, again only when its run file changed.
    private func measureDiskUsage() {
        let finished = runs.filter { $0.status == .done }
        let ids = Set(finished.map(\.id))
        diskUsage = diskUsage.filter { ids.contains($0.key) }
        measuredAt = measuredAt.filter { ids.contains($0.key) }
        let runner = untimedRunner
        for run in finished {
            guard let worktree = run.worktree, measuredAt[run.id] != run.updatedAt else { continue }
            measuredAt[run.id] = run.updatedAt
            let runID = run.id
            let version = run.updatedAt
            Task { [weak self] in
                let bytes = await Task.detached { TicketPilotCore.diskUsage(of: worktree, runner: runner) }.value
                // A newer measure of the same run (or its removal) wins over this one.
                guard let self, self.measuredAt[runID] == version else { return }
                self.diskUsage[runID] = bytes
            }
        }
    }

    // MARK: - Tickets

    /// Why Start is disabled for this ticket, or nil when it can start.
    func startBlockReason(_ issue: JiraIssue) -> String? {
        guard let config else { return "No valid config" }
        return health.startBlocker(for: route(for: issue, config: config))?.detail
    }

    func startTicket(_ issue: JiraIssue) {
        guard let config else { return }
        let route = route(for: issue, config: config)
        if let blocker = health.startBlocker(for: route) {
            Alerts.show(AlertText(
                title: "\(issue.key) cannot start",
                message: [blocker.detail, blocker.fix].compactMap { $0 }.joined(separator: "\n\n")
            ))
            return
        }
        switch route {
        case let .direct(repo):
            launch([RepoChoice(repo: repo, matched: true, existingRunID: nil)], issue: issue)
        case let .pick(choices):
            picker.show(issue: issue, choices: choices, health: health) { [weak self] picked in
                self?.launch(picked, issue: issue)
            }
        }
    }

    /// One run per chosen repo: a repo that already has a run of this ticket is resumed instead.
    func launch(_ choices: [RepoChoice], issue: JiraIssue) {
        picker.close()
        guard let config else { return }
        afterTerminalResolved { [self] in
            for choice in choices where health.canStart(repo: choice.repo.name) {
                if let runID = choice.existingRunID {
                    resume(runID: runID)
                    continue
                }
                do {
                    let command = try SessionCommand.start(
                        key: issue.key, repoPath: choice.repo.expandedPath, permissionMode: config.permissionMode
                    )
                    terminal()?.open(command)
                } catch {
                    Alerts.show(AlertText(title: "\(issue.key) cannot start", message: "\(error)"))
                }
            }
        }
    }

    func openInJira(_ issue: JiraIssue) {
        openInJira(key: issue.key)
    }

    private func route(for issue: JiraIssue, config: AppConfig) -> StartRoute {
        StartRoute.make(choices: RepoMatcher.choices(for: issue, repos: config.repos, runs: runs))
    }

    private func openInJira(key: String) {
        guard let config else { return }
        NSWorkspace.shared.open(config.jira.browseURL(key: key))
    }

    // MARK: - Run actions

    /// Follows `SessionAction.forOpening`: reopen an ended session, start a missing one, or bring the
    /// terminal to the front for a live one. With Ghostty, which is scriptable, the session's own tab is
    /// focused instead, and a session with no tab is resumed in a new one.
    func openSession(runID: String) {
        afterTerminalResolved { [self] in openSessionNow(runID: runID) }
    }

    private func openSessionNow(runID: String) {
        acknowledgeIfDone(runID)
        guard let run = runs.first(where: { $0.id == runID }) else { return }
        let action = SessionAction.forOpening(run)
        if config != nil, terminalChoice.isGhostty {
            openInGhostty(run, action: action)
            return
        }
        switch action {
        case .resume, .start:
            resume(runID: runID)
        case .bringToFront:
            terminal()?.activate()
        }
    }

    /// Focuses the run's Ghostty tab, else opens its session in a new tab. A session believed ended only
    /// reuses a tab titled like Claude Code, never a plain shell. `findTab` is false for the explicit
    /// "Resume" and for a run without session, which always open a new tab. A scripting failure is reported
    /// once per kind; then a live session just brings Ghostty to the front and anything else goes through
    /// the `.command` launcher.
    private func openInGhostty(_ run: Run, action: SessionAction, findTab: Bool = true) {
        guard !ghosttyBusyRuns.contains(run.id) else { return }
        let command: String
        do {
            command = try SessionCommand.resume(run, permissionMode: config?.permissionMode)
        } catch {
            Alerts.show(AlertText(title: "\(run.key) cannot resume", message: "\(error)"))
            return
        }
        // Long enough to answer the Automation prompt, finite so a hung osascript cannot block the run forever.
        let controller = GhosttyController(runner: ghosttyRunner)
        let folders = SessionLocator.candidateFolders(for: run)
        let directory = run.worktree ?? run.repoPath
        let runID = run.id
        let live = action == .bringToFront
        ghosttyBusyRuns.insert(run.id)
        Task { [weak self] in
            let failure = await Task.detached { () -> GhosttyError? in
                do {
                    if findTab, action != .start {
                        let terminals = try controller.listTerminals()
                        if let id = SessionLocator.pickTerminal(terminals, folders: folders, claudeOnly: !live) {
                            try controller.focus(terminalID: id)
                            return nil
                        }
                    }
                    try controller.openTab(directory: directory, command: command)
                    return nil
                } catch let error as GhosttyError {
                    return error
                } catch {
                    return .scriptFailed("\(error)")
                }
            }.value
            guard let self else { return }
            ghosttyBusyRuns.remove(runID)
            guard let failure else { return }
            if ghosttyAlertsShown.insert(failure.kind).inserted {
                Alerts.show(failure.alertText)
            }
            if live {
                terminal()?.activate()
            } else {
                resumeWithLauncher(runID: runID)
            }
        }
    }

    func resume(runID: String) {
        afterTerminalResolved { [self] in resumeNow(runID: runID) }
    }

    private func resumeNow(runID: String) {
        guard let run = runs.first(where: { $0.id == runID }) else { return }
        if config != nil, terminalChoice.isGhostty {
            openInGhostty(run, action: .resume, findTab: false)
            return
        }
        resumeWithLauncher(runID: runID)
    }

    private func resumeWithLauncher(runID: String) {
        guard let run = runs.first(where: { $0.id == runID }) else { return }
        do {
            terminal()?.open(try SessionCommand.resume(run, permissionMode: config?.permissionMode))
        } catch {
            Alerts.show(AlertText(title: "\(run.key) cannot resume", message: "\(error)"))
        }
    }

    func release(runID: String) {
        guard releasable.contains(runID), let run = runs.first(where: { $0.id == runID }) else { return }
        let mainBranch = config?.repos.first { $0.name == run.repo }?.mainBranch
        let plan = ReleasePlan.make(run: run, runsDirectory: paths.runsDirectory, mainBranch: mainBranch)
        guard Alerts.confirmRelease(run, plan: plan) else { return }
        let releaser = Releaser(runner: untimedRunner)
        Task { [weak self] in
            let failure = await Task.detached { () -> ReleaseError? in
                do throws(ReleaseError) {
                    try releaser.release(plan)
                    return nil
                } catch {
                    return error
                }
            }.value
            if let failure {
                Alerts.show(failure.alertText)
            } else {
                self?.releasable.remove(runID)
            }
            self?.refreshRuns()
        }
    }

    private func acknowledgeIfDone(_ runID: String) {
        guard runs.contains(where: { $0.id == runID && $0.status == .done }),
              acknowledged.insert(runID).inserted
        else { return }
        try? acknowledgedStore.save(acknowledged)
        updatePresentation()
    }

    private func terminal() -> Terminal? {
        guard config != nil else { return nil }
        return Terminal(launcher: TerminalLauncher(
            appName: terminalChoice.appName,
            scriptsDirectory: paths.appDirectory.appendingPathComponent("scripts", isDirectory: true),
            runner: runner
        ))
    }

    // MARK: - Settings, About and notifications

    func showSettings() {
        settingsWindow.show(title: "TicketPilot Settings", resizable: true) { SettingsView(model: self) }
    }

    func showAbout() {
        aboutWindow.show(title: "About TicketPilot") { AboutView() }
    }

    func sendFeedback() {
        NSWorkspace.shared.open(AboutView.issuesURL)
    }

    /// Writes `terminal_app` into the config (nil removes it, for "Automatic"), every other key kept.
    func setTerminalApp(_ name: String?) {
        guard name != selectedTerminal else { return }
        // A symlinked config is edited where it points, not replaced by a plain file.
        let file = paths.configFile.resolvingSymlinksInPath()
        do {
            let data = try Data(contentsOf: file)
            try ConfigEditor.setTerminalApp(name, in: data).write(to: file, options: .atomic)
        } catch {
            let detail = switch error {
            case ConfigEditError.invalidJSON: "\(file.path) is not valid JSON."
            case ConfigEditError.notAnObject: "\(file.path) does not hold a JSON object."
            case ConfigEditError.invalidName: "This terminal name cannot be saved."
            default: error.localizedDescription
            }
            Alerts.show(AlertText(title: "The terminal was not changed", message: detail))
        }
        runDoctor()
    }

    func setOpenAtLogin(_ enabled: Bool) {
        guard hasBundle else { return }
        do {
            try LoginItem.set(enabled)
        } catch {
            Alerts.show(AlertText(title: "Open at login was not changed", message: error.localizedDescription))
        }
        openAtLogin = LoginItem.isEnabled
    }

    /// Does what the setup button offers for the setup problem.
    func fixSetupProblem() {
        guard let setupProblem else { return }
        switch setupProblem.action {
        case let .openURL(url): NSWorkspace.shared.open(url)
        case let .copyFix(check): copyFix(of: check)
        case .setJiraToken: setJiraToken()
        case let .explain(text): Alerts.show(text)
        case .checkAgain: runDoctor()
        case let .installPlugin(state): installPlugin(state)
        }
    }

    // MARK: - Plugin

    /// The plugin copy inside the app bundle, if this is a bundle that carries one.
    private var bundledPlugin: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("plugin", isDirectory: true),
              FileManager.default.fileExists(atPath: url.appendingPathComponent(".claude-plugin/plugin.json").path)
        else { return nil }
        return url
    }

    /// Reads the configured marketplaces, lists the commands it will run and asks first; then runs them and
    /// checks the setup again. Nothing runs without the confirmation.
    func installPlugin(_ state: PluginState) {
        guard !installingPlugin, let claudePath = health.claudePath else { return }
        installingPlugin = true
        let installer = PluginInstaller(claudePath: claudePath, bundledPlugin: bundledPlugin, runner: pluginRunner)
        let installed = state != .missing
        Task { [weak self] in
            let plan = await Task.detached {
                Result<[PluginCommand], PluginInstallError> { () throws(PluginInstallError) in
                    try installer.plan(pluginInstalled: installed)
                }
            }.value
            guard let self else { return }
            let commands: [PluginCommand]
            switch plan {
            case let .success(planned): commands = planned
            case let .failure(error):
                installingPlugin = false
                Alerts.show(error.alertText)
                return
            }
            guard Alerts.confirm(PluginInstaller.confirmation(commands), button: "Install") else {
                installingPlugin = false
                return
            }
            let outcome = await Task.detached {
                Result<[PluginCommandResult], PluginInstallError> { () throws(PluginInstallError) in
                    try installer.run(commands)
                }
            }.value
            installingPlugin = false
            switch outcome {
            case let .success(results):
                let log = results.map { result in
                    let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    return output.isEmpty ? result.command.display : "\(result.command.display)\n\(output)"
                }
                Alerts.show(AlertText(
                    title: "Plugin installed — restart your Claude Code sessions to use it",
                    message: log.joined(separator: "\n\n")
                ))
            case let .failure(error):
                Alerts.show(error.alertText)
            }
            runDoctor()
        }
    }

    func copyFix(of check: HealthCheck) {
        guard let fix = check.fix else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fix, forType: .string)
        notifier?.notifyCopied()
        AccessibilityNotification.Announcement("Copied").post()
        copiedFix = check.id
        copiedTask?.cancel()
        copiedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.copiedFix = nil
        }
    }

    // MARK: - Jira token

    /// Asks for the token, stores it in the Keychain and checks the setup again.
    func setJiraToken() {
        guard let config else { return }
        guard let answer = Alerts.askJiraToken(site: config.jira.site.absoluteString, email: config.jira.email) else {
            return
        }
        guard let token = answer.nonEmpty else {
            Alerts.show(AlertText(title: "The token is empty", message: "Nothing was saved."))
            return
        }
        let service = config.jira.keychainService
        let account = NSUserName()
        Task { [weak self] in
            let result = await Task.detached {
                Result<Void, KeychainError> { () throws(KeychainError) in
                    try Keychain.setPassword(token, service: service, account: account)
                }
            }.value
            switch result {
            case .success:
                self?.runDoctor()
            case let .failure(error):
                let detail = if case let .unexpected(status) = error { "Keychain status \(status)" } else { "\(error)" }
                Alerts.show(AlertText(title: "The Jira token was not saved", message: detail))
            }
        }
    }

    private func handle(_ action: NotificationAction) {
        switch action {
        case let .startTicket(key):
            if let issue = issues.first(where: { $0.key == key }) { startTicket(issue) }
        case let .openInJira(key):
            openInJira(key: key)
        case let .openSession(runID):
            openSession(runID: runID)
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private func freeBytesOnHomeVolume() -> Int64? {
    let values = try? FileManager.default.homeDirectoryForCurrentUser
        .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage
}

