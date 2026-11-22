import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import TicketPilotCore

/// The app state shown in the panel, and every action the panel, Settings or a notification can trigger.
@MainActor @Observable
final class AppModel {
    private(set) var todo = TodoList(issues: [], readyStatuses: [])
    /// The newly assigned tickets not shown in the panel yet, listed under "New" above the runs.
    private(set) var newTickets = NewTickets()
    private(set) var runGroups: [RunGroup] = []
    private(set) var iconState: RunIconState = .idle
    /// Also true while there is no valid config or no token: Jira is not read at all.
    private(set) var jiraFailing = false
    private(set) var health: [HealthCheck] = []
    /// The Jira status category of each run's ticket, from the last poll.
    private var ticketCategories: [String: JiraIssue.StatusCategory] = [:]
    /// The runs that can be released: finished, or with their ticket Done in Jira.
    var releasable: Set<String> { Releasable.runIDs(runs: runs, categories: ticketCategories) }
    private(set) var configError: String?
    /// Why the config can't be used yet, for the setup banner: none, broken, or the example as is.
    private(set) var configProblem: SetupProblem.ConfigProblem?
    private(set) var openAtLoginState = false
    /// Disk usage of each run's worktree, by run id.
    private(set) var diskUsage: [String: Int64] = [:]
    /// Commits of each finished run, ready for review, by run id.
    private(set) var commitCounts: [String: Int] = [:]
    /// The runs being removed (worktree, branches, run file), by run id: their card reads "Removing…".
    private(set) var releasing: Set<String> = []
    /// The git client finished runs are reviewed in (`git_client`, else the first known one installed).
    private(set) var gitClient: String?
    /// The editor each run's worktree opens in, by run id; none when no installed app fits.
    private(set) var editors: [String: EditorTarget] = [:]
    /// The known editors installed, looked for with the git clients at each config load.
    @ObservationIgnored private var installedEditors: [String] = []
    /// The exact copy of each known editor and git client installed: the newest one.
    @ObservationIgnored private var appPaths: [String: String] = [:]
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
    /// From "Refresh" until Jira answered, or failed to.
    private(set) var refreshingTickets = false
    /// When Jira last answered with the assigned tickets.
    private var ticketsUpdatedAt: Date?
    /// Moved on each minute, so that "Tickets updated N min ago" follows the time.
    private var clock = Date()
    /// "Tickets updated 3 min ago", or "Updating tickets…": what the refresh button reads, and when.
    var ticketsFreshness: String? {
        TicketsFreshness.text(lastUpdate: ticketsUpdatedAt, refreshing: refreshingTickets, now: clock)
    }
    private(set) var runs: [Run] = []
    /// Tickets whose Start was clicked and whose run has not appeared yet.
    private(set) var startingTickets = StartingTickets()
    private(set) var acknowledged: Set<String> = []
    /// The Jira summary of each assigned ticket, by key: the title of a run that has none of its own.
    private(set) var summaries: [String: String] = [:]
    /// True from the plugin install's confirmation until its last command has run.
    private(set) var installingPlugin = false
    /// An Atlassian sign-in is stored, whether or not Atlassian accepts it.
    private(set) var hasAtlassianSignIn = false
    /// The email of the signed-in Atlassian account, once Atlassian told it.
    private(set) var jiraAccount: String?
    /// From "Connect Jira" until the browser came back, or the sign-in was cancelled.
    private(set) var signingIn = false
    /// From "Check again" (or any setup check) until its results are in.
    private(set) var checkingSetup = false
    /// When the last setup check ended, shown under Diagnostics.
    private(set) var lastSetupCheck: Date?

    /// `UNUserNotificationCenter` and `SMAppService` need a `.app` bundle.
    let hasBundle = Bundle.main.bundleIdentifier != nil

    var icon: MenuBarIcon {
        MenuBarIcon.make(iconState: iconState, hasSetupProblem: setupProblem != nil, hasNewTickets: newTickets.hasUnshown)
    }

    /// The problem the panel offers to fix, if any.
    var setupProblem: SetupProblem? {
        let problem = SetupProblem.first(in: health, config: configProblem, jiraFailing: jiraFailing)
        // Signed in, but to an account with no Jira site: connecting again would change nothing.
        if noJiraSite, configProblem == .missing, problem?.action == .connectAtlassian { return SetupProblem.noJiraSite }
        return problem
    }

    /// The signed-in Atlassian account can open no Jira site, so no config could be written.
    private(set) var noJiraSite = false
    /// Reading the account to write the Jira site, after a sign-in.
    @ObservationIgnored private var settingUpJira = false
    /// Whether this launch (or the last sign-in) already tried to write the config from a stored sign-in.
    @ObservationIgnored private var jiraSetupTried = false

    /// Jira can be read: an Atlassian sign-in and a config that loads. Until then, the panel offers no
    /// refresh of the tickets: its setup banner says what to do.
    var readsJira: Bool {
        hasAtlassianSignIn && configProblem != .missing && !configIsBroken
    }

    /// A config that exists but does not load: what depends on it in Settings waits for the fix.
    var configIsBroken: Bool {
        if case .invalid = configProblem { true } else { false }
    }

    /// The repositories of the config, for Settings: observed, unlike `config`, so the list follows each
    /// edit.
    private(set) var repositories: [RepoConfig] = []

    /// The setup button: "Copied ✓" for a few seconds once its fix command is copied.
    var setupProblemTitle: String? {
        guard let setupProblem else { return nil }
        if case let .copyFix(check) = setupProblem.action, copiedFix == check.id { return "Copied ✓" }
        return setupProblem.buttonTitle
    }

    /// The status at the top of the panel, only when the user must act.
    var status: PanelStatus? {
        PanelStatus.make(runs: runs, setupProblem: setupProblem, signingIn: signingIn)
    }

    /// What the empty list says ("No tickets assigned to you"), once Jira answered.
    var emptyListText: String? {
        PanelStatus.emptyListText(
            hasRuns: !runs.isEmpty, todoCount: jiraAnswered ? todo.count : nil
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
    @ObservationIgnored private var scriptableAlertsShown: Set<String> = []
    @ObservationIgnored private var scriptableBusyRuns: Set<String> = []
    /// "<key>|<repo>" of the starts still opening their tab: a second Start meanwhile is ignored.
    @ObservationIgnored private var scriptableStarting: Set<String> = []
    // Long enough to answer Ghostty's Automation prompt, finite so a hung call cannot block a run forever.
    @ObservationIgnored private let scriptableRunner = SystemProcessRunner(timeout: 300)
    /// `claude plugin marketplace update` may clone a repository: generous, but finite.
    @ObservationIgnored private let pluginRunner = SystemProcessRunner(timeout: 300)
    /// For `git worktree remove` and `du` on a big worktree, which must not be killed midway.
    /// Only used off the main actor.
    @ObservationIgnored private let untimedRunner = SystemProcessRunner()
    @ObservationIgnored private let sleepGuard = SleepGuard()
    @ObservationIgnored private let picker = RepoPickerWindow()
    @ObservationIgnored private let addRepositoriesWindow = AddRepositoriesWindow()
    @ObservationIgnored private let settingsWindow = AuxiliaryWindow()
    @ObservationIgnored private let aboutWindow = AuxiliaryWindow()
    @ObservationIgnored private let reportWindows = ReportWindows()
    @ObservationIgnored private var config: AppConfig?
    @ObservationIgnored private var poller: JiraPoller?
    @ObservationIgnored private var notifier: Notifier?
    @ObservationIgnored private var watcher: RunWatcher?
    @ObservationIgnored private var issues: [JiraIssue] = []
    @ObservationIgnored private var needsYou = NeedsYouTracker()
    /// The plain ends of turn waiting their two minutes before a silent notification, by run id.
    @ObservationIgnored private var quietWaits: [String: (since: Date, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var terminalTask: Task<Void, Never>?
    @ObservationIgnored private var doctorTask: Task<Void, Never>?
    @ObservationIgnored private var copiedTask: Task<Void, Never>?
    /// The Atlassian Remote MCP sign-in, kept in the Keychain (`ticket-pilot-atlassian-mcp`).
    @ObservationIgnored private let atlassianAuth = AtlassianMCPAuth()
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSignIn: MCPSignIn?
    /// The sign-in in progress, so that a cancelled one never ends a newer one.
    @ObservationIgnored private var signInID: UUID?
    /// The run version (`updatedAt`) each size was measured for, or is being measured for.
    @ObservationIgnored private var measuredAt: [String: Date] = [:]
    /// What each commit count was made for, or is being made for: the run version (`updatedAt`) and the
    /// main branch, so that a config change counts again.
    @ObservationIgnored private var countedFor: [String: CommitCountKey] = [:]

    private var acknowledgedStore: SeenStore {
        SeenStore(file: paths.appDirectory.appendingPathComponent("acknowledged.json"))
    }

    /// Where the tickets seen and the new tickets are kept: with made-up tickets, in a folder of this launch
    /// only, so that a debug run never changes the real ones.
    @ObservationIgnored private let ticketStateDirectory: URL = DebugFlags.current.fakeTicketCount == nil
        ? StatePaths().appDirectory
        : FileManager.default.temporaryDirectory.appendingPathComponent("ticket-pilot-debug-\(UUID().uuidString)")
    /// The reads of the made-up Jira since launch: from the second one, it assigns a new ticket.
    @ObservationIgnored private let debugJiraReads = DebugJiraReads()

    private var newTicketsStore: SeenStore {
        SeenStore(file: ticketStateDirectory.appendingPathComponent("new-tickets.json"))
    }

    // MARK: - Start

    func start() {
        guard watcher == nil else { return }
        if hasBundle {
            notifier = Notifier { [weak self] in self?.handle($0) }
            notifier?.requestAuthorization()
            LoginItem.registerOnce(marker: paths.appDirectory.appendingPathComponent("login-item-registered"))
            openAtLoginState = LoginItem.isEnabled
        }
        newTickets = NewTickets.load(from: newTicketsStore)
        poller = JiraPoller(seenStore: SeenStore(file: ticketStateDirectory.appendingPathComponent("seen.json"))) {
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
                self?.clock = Date()
                self?.updatePresentation()
            }
        }
        runDoctor()
    }

    /// Reloads the config and the Jira token (or the Atlassian sign-in), checks the setup and polls Jira at once.
    func runDoctor() {
        doctorTask?.cancel()
        loadConfig()
        checkingSetup = true
        // Without a config, or with a broken one, Jira is not read: Claude Code and the plugin are still
        // checked, so a first launch starts with them. Without a config, a stored sign-in writes it.
        guard let config, !configIsBroken else {
            poller?.stop()
            refreshingTickets = false
            jiraFailing = true
            if configProblem == .missing, !jiraSetupTried {
                jiraSetupTried = true
                completeJiraSetup(signInIfNeeded: false)
            }
            let doctor = makeDoctor(config: nil, jira: nil, signInLookup: { throw KeychainError.notFound })
            doctorTask = Task { [weak self] in
                let checks = await Task.detached { await doctor.run() }.value
                guard !Task.isCancelled, let self else { return }
                health = checks
                checkingSetup = false
                lastSetupCheck = Date()
            }
            return
        }
        let auth = atlassianAuth
        let debugJiraReads = debugJiraReads
        doctorTask = Task { [weak self] in
            let token: Result<String, KeychainError>
            let jira: (any JiraSearching)?
            if let count = DebugFlags.current.fakeTicketCount {
                token = .success("debug")
                jira = DebugJira(count: count, reads: debugJiraReads)
            } else {
                token = await Self.atlassianSignIn(auth)
                jira = (try? token.get()).map { _ in
                    MCPJiraClient(site: config.jira.site, tools: MCPClient(url: auth.server, tokens: auth, clientVersion: Self.version))
                }
            }
            guard !Task.isCancelled, let self else { return }
            hasAtlassianSignIn = (try? token.get()) != nil
            if !hasAtlassianSignIn { jiraAccount = nil }
            if let jira {
                poller?.start(jira: jira, pollMinutes: config.pollMinutes)
            } else {
                poller?.stop()
                refreshingTickets = false
                jiraFailing = true
            }
            let doctor = makeDoctor(config: config, jira: jira, signInLookup: { try token.get() })
            let checks = await Task.detached { await doctor.run() }.value
            guard !Task.isCancelled else { return }
            health = checks
            checkingSetup = false
            lastSetupCheck = Date()
            if let mcp = jira as? MCPJiraClient, checks.contains(where: { $0.id == .jiraSignIn && $0.ok }) {
                let email = try? await mcp.accountEmail()
                guard !Task.isCancelled else { return }
                jiraAccount = email
            }
        }
    }

    private func makeDoctor(
        config: AppConfig?, jira: (any JiraSearching)?, signInLookup: @escaping @Sendable () throws -> String
    ) -> Doctor {
        Doctor(
            config: config,
            home: FileManager.default.homeDirectoryForCurrentUser,
            runner: runner,
            jira: jira,
            signInLookup: signInLookup,
            freeBytes: freeBytesOnHomeVolume,
            bundledPluginManifest: Doctor.bundledPluginManifest(resources: Bundle.main.resourceURL)
        )
    }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// Whether an Atlassian sign-in is stored, as the doctor's token lookup reads it: `.notFound` without
    /// one, `.unexpected` when the Keychain refused. The sign-in itself never leaves the Keychain item.
    private nonisolated static func atlassianSignIn(_ auth: AtlassianMCPAuth) async -> Result<String, KeychainError> {
        do {
            return try await auth.isConnected() ? .success("") : .failure(.notFound)
        } catch {
            if case let .keychain(status) = error { return .failure(.unexpected(status)) }
            return .failure(.notFound)
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
            configProblem = config?.repos.isEmpty == true ? .noRepos : nil
            repositories = config?.repos ?? []
            configuredTerminal = config?.terminalApp
            resolveTerminal(configured: config?.terminalApp)
            // Runs are read before the config at launch: what depends on it is derived again.
            // The newest copy of each known app, found once (Xcode_27.1 over Xcode_27, a Preview over a release).
            appPaths = ApplicationFinder().paths(among: ToolChoice.knownEditors + ToolChoice.gitClients)
            gitClient = ToolChoice.gitClient(
                configured: config?.gitClient, installed: ToolChoice.gitClients.filter { appPaths[$0] != nil }
            )
            installedEditors = ToolChoice.knownEditors.filter { appPaths[$0] != nil }
            updateEditors()
            countCommits()
            updatePresentation()
        } catch {
            config = nil
            configuredTerminal = nil
            configError = switch error {
            case let .missing(path): "not found at \(path)"
            case let .invalid(message): message
            }
            configProblem = switch error {
            case .missing: .missing
            case let .invalid(message): .invalid(message)
            }
            repositories = []
            updatePresentation()
        }
    }

    // MARK: - Jira

    /// Reads the assigned tickets again now; without a Jira to read (no sign-in, no config), checks the setup
    /// again, which polls once it can.
    func refreshTickets() {
        if !pollTicketsNow() { runDoctor() }
    }

    /// Reads Jira now, the refresh button spinning until it answered; false when Jira is not read at all.
    @discardableResult
    private func pollTicketsNow() -> Bool {
        guard poller?.pollNow() == true else { return false }
        refreshingTickets = true
        return true
    }

    private func apply(_ outcome: PollOutcome, from jira: any JiraSearching) async {
        refreshingTickets = false
        switch outcome {
        case .failed:
            jiraFailing = true
        case let .succeeded(issues, notified):
            jiraFailing = false
            jiraAnswered = true
            clock = Date()
            ticketsUpdatedAt = clock
            self.issues = issues
            summaries = Dictionary(issues.map { ($0.key, $0.summary) }, uniquingKeysWith: { first, _ in first })
            updateNewTickets { $0.add(notified.map(\.key)) }
            updatePresentation()
            rebuildTodo()
            notified.forEach { notifier?.notifyNewTicket($0) }
            await refreshReleasable(jira)
        }
    }

    /// A failure here only keeps the previous set: it never affects polling or the todo list.
    private func refreshReleasable(_ jira: any JiraSearching) async {
        let polledRuns = runs
        let keys = Set(polledRuns.map(\.key)).sorted()
        guard !keys.isEmpty, let categories = try? await jira.statusCategories(of: keys) else { return }
        ticketCategories = categories
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

    /// The tickets new, in progress and to do, without those that have a run. A new ticket the list no longer
    /// shows stops being new, once Jira answered: before, the tickets listed are not known yet.
    private func rebuildTodo() {
        todo = makeTodo()
        updateNewTickets { $0.keepOnly(jiraAnswered ? todo.listedKeys : nil) }
    }

    private func makeTodo() -> TodoList {
        TodoList(
            issues: issues, readyStatuses: config?.readyStatuses ?? [], finishedStatuses: config?.finishedStatuses ?? [],
            keysWithRuns: TodoList.keysWithRuns(runs), newKeys: newTickets.keys
        )
    }

    /// Changes the new tickets, and only when they did change, notifies the icon; when the tickets themselves
    /// changed (a close of the panel, a poll), saves the file and lists them again, so that a ticket shown
    /// before a close is no longer under "New" at the next opening. The list is rebuilt at each poll and each
    /// run file change, so most calls change nothing.
    private func updateNewTickets(_ change: (inout NewTickets) -> Void) {
        var updated = newTickets
        change(&updated)
        guard updated != newTickets else { return }
        let keysChanged = updated.keys != newTickets.keys
        newTickets = updated
        guard keysChanged else { return }
        try? newTickets.save(to: newTicketsStore)
        todo = makeTodo()
    }

    /// Posts a needs-you notification as `NotificationPolicy` says: at once, or (a plain end of turn) two
    /// minutes later, silently, if the same wait is still pending then.
    private func schedule(_ event: NeedsYouEvent) {
        let identifier = event.notificationID(in: runs)
        switch NotificationPolicy.timing(for: event, in: runs, now: Date()) {
        case let .now(sound):
            deliver(event, identifier: identifier, sound: sound)
        case let .after(deadline, since):
            let runID = event.runID
            quietWaits[runID]?.task.cancel()
            let task = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                guard !Task.isCancelled, let self,
                      NotificationPolicy.isStillPending(runID: runID, since: since, in: runs)
                else { return }
                quietWaits[runID] = nil
                deliver(event, identifier: identifier, sound: false)
            }
            quietWaits[runID] = (since, task)
        }
    }

    /// Posts the notification unless the user is looking at the run's session: Ghostty in front, on a tab
    /// named after the ticket. Any failure to tell just notifies.
    private func deliver(_ event: NeedsYouEvent, identifier: String, sound: Bool) {
        guard let notifier else { return }
        let key = runs.first { $0.id == event.runID }?.key
        let ghosttyInFront = NSWorkspace.shared.frontmostApplication?.localizedName == "Ghostty"
        guard case .waiting = event, ghosttyInFront, terminalChoice.isGhostty, let key else {
            notifier.notify(event, identifier: identifier, sound: sound)
            return
        }
        let controller = GhosttyController(runner: SystemProcessRunner(timeout: 5))
        Task { [weak self] in
            let title = await Task.detached { try? controller.selectedTabTitle() }.value ?? nil
            if NotificationPolicy.userIsWatching(frontmostIsGhostty: true, selectedTabTitle: title, key: key) { return }
            self?.notifier?.notify(event, identifier: identifier, sound: sound)
        }
    }

    private func refreshRuns() {
        runs = RunStore(directory: paths.runsDirectory).loadAll()
        rebuildTodo()
        for event in needsYou.events(for: runs) {
            schedule(event)
        }
        // A plain end of turn answered (or replaced) within its two minutes is never notified.
        for (runID, wait) in quietWaits where !NotificationPolicy.isStillPending(runID: runID, since: wait.since, in: runs) {
            wait.task.cancel()
            quietWaits[runID] = nil
        }
        updatePresentation()
        measureDiskUsage()
        countCommits()
        updateEditors()
    }

    /// Also run every minute, so a run interrupted without a status update stops keeping the Mac awake.
    private func updatePresentation() {
        iconState = RunIconState.make(runs: runs, acknowledgedDone: acknowledged)
        let now = Date()
        startingTickets.settle(runs: runs, now: now)
        let stuckMinutes = config?.stuckMinutes ?? [:]
        runGroups = RunGroup.make(
            runs: runs, now: now, stuckMinutes: stuckMinutes, summaries: summaries, commits: commitCounts,
            jiraStatuses: Dictionary(issues.map { ($0.key, $0.statusName) }, uniquingKeysWith: { first, _ in first })
        )
        sleepGuard.update(anyRunning: SleepPolicy.keepsMacAwake(runs: runs, now: now, stuckMinutes: stuckMinutes))
    }

    /// "Show in Finder · <size>" for a run with a worktree.

    func showInFinderTitle(runID: String) -> String? {
        runs.first { $0.id == runID }.flatMap { RunLine.showInFinderTitle($0, bytes: diskUsage[runID]) }
    }

    /// "Remove worktree…", or "Remove from the list…" for a run that never had a worktree.
    func releaseTitle(runID: String) -> String? {
        runs.first { $0.id == runID }.map(Releasable.actionTitle(for:))
    }

    func isTestOnly(runID: String) -> Bool {
        runs.first { $0.id == runID }?.testOnly == true
    }

    /// The run's worktree is still on disk: an earlier removal may have deleted it, its run kept.
    func hasWorktree(runID: String) -> Bool {
        runs.first { $0.id == runID }.map(Releasable.worktreeExists) ?? false
    }

    /// Picks the editor of each run with a worktree, from its root folder's entries.
    private func updateEditors() {
        var editors: [String: EditorTarget] = [:]
        for run in runs {
            guard let worktree = run.worktree,
                  let entries = try? FileManager.default.contentsOfDirectory(atPath: worktree)
            else { continue }
            let configured = config?.repos.first { $0.name == run.repo }?.editor
            editors[run.id] = ToolChoice.editor(
                configured: configured, worktree: worktree, entries: entries, installed: installedEditors,
                appPaths: appPaths
            )
        }
        self.editors = editors
    }

    /// Opens the finished run's worktree in the git client, to review its commits.
    func reviewInGitClient(runID: String) {
        guard let app = gitClient, let worktree = runs.first(where: { $0.id == runID })?.worktree else { return }
        openTool(EditorTarget(app: app, path: worktree, appPath: appPaths[app]))
    }

    /// Opens the run's worktree (or its Xcode project) in its editor.
    func openInEditor(runID: String) {
        guard let target = editors[runID] else { return }
        openTool(target)
    }

    /// `open -a` blocks until the app answers: off the main actor, a failure in an alert.
    private func openTool(_ target: EditorTarget) {
        let launcher = ToolLauncher(runner: runner)
        Task.detached {
            do {
                try launcher.open(target)
            } catch {
                await Alerts.show(AlertText(title: "\(target.app) did not open", message: "\(error)"))
            }
        }
    }

    /// Reveals the run's worktree in the Finder.
    func revealWorktree(runID: String) {
        guard let path = runs.first(where: { $0.id == runID })?.worktree else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Counts the commits of each finished run off the main actor, again only when its run file, its repo's
    /// main branch or the commit `origin/<main>` points to changed (after a fetch: the app never fetches).
    /// Without a worktree or a known main branch (no config yet), nothing is recorded, so the run is counted
    /// once the config is loaded; the card says "ready for review" meanwhile.
    private func countCommits() {
        let finished = runs.filter { $0.status == .done }
        let ids = Set(finished.map(\.id))
        commitCounts = commitCounts.filter { ids.contains($0.key) }
        countedFor = countedFor.filter { ids.contains($0.key) }
        let counter = CommitCounter(runner: untimedRunner)
        for run in finished {
            guard let worktree = run.worktree,
                  let mainBranch = config?.repos.first(where: { $0.name == run.repo })?.mainBranch
            else { continue }
            let runID = run.id
            let updatedAt = run.updatedAt
            Task { [weak self] in
                let head = await Task.detached { counter.mainHead(worktree: worktree, mainBranch: mainBranch) }.value
                let version = CommitCountKey(updatedAt: updatedAt, mainBranch: mainBranch, mainHead: head)
                guard let self, self.countedFor[runID] != version else { return }
                self.countedFor[runID] = version
                let count = await Task.detached {
                    counter.count(worktree: worktree, mainBranch: mainBranch)
                }.value
                // A newer count of the same run (or its removal) wins over this one.
                guard self.countedFor[runID] == version else { return }
                self.commitCounts[runID] = count
                self.updatePresentation()
            }
        }
    }

    /// The panel opened: the new tickets are on screen, the tickets are read again when the list is old, and
    /// the runs whose `origin/<main>` moved since their last count are counted again.
    func panelOpened() {
        updateNewTickets { $0.panelOpened() }
        if TicketsFreshness.needsRead(lastUpdate: ticketsUpdatedAt, now: Date()) {
            pollTicketsNow()
        }
        countCommits()
        // The config is not watched: while it can't be used, each opening reads it again, so the banner moves
        // on once the user saved it.
        if configProblem != nil { runDoctor() }
    }

    /// The panel closed, or the app quits: the new tickets it showed are no longer new.
    func panelClosed() {
        updateNewTickets { $0.panelClosed() }
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

    /// The ticket's Start was clicked and its run has not appeared yet: its button reads "Starting…".
    func isStarting(_ issue: JiraIssue) -> Bool {
        startingTickets.contains(issue.key)
    }

    func startTicket(_ issue: JiraIssue) {
        guard let config, !startingTickets.contains(issue.key) else { return }
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
                    startingTickets.mark(issue.key, at: Date())
                    if terminalChoice.isScriptable {
                        startInScriptable(command, directory: choice.repo.expandedPath, key: issue.key)
                    } else {
                        terminal()?.open(command)
                    }
                } catch {
                    Alerts.show(AlertText(title: "\(issue.key) cannot start", message: "\(error)"))
                }
            }
        }
    }

    /// The controller of the chosen scriptable terminal; nil (after an alert) when Orca's CLI is missing.
    private func scriptableController() -> (any ScriptableTerminal)? {
        if terminalChoice.isGhostty {
            return GhosttyController(runner: scriptableRunner)
        }
        guard let cli = OrcaController.cliPath() else {
            reportScriptableFailure(OrcaError.notInstalled)
            return nil
        }
        return OrcaController(runner: scriptableRunner, cli: cli)
    }

    /// Tab title for a run's session: Orca shows it as set; Ghostty lets Claude Code title its tab.
    private nonisolated static func tabTitle(key: String) -> String {
        "\(key) · claude"
    }

    /// A failure of the scriptable terminal, shown once per terminal and kind.
    private func reportScriptableFailure(_ failure: any ScriptableTerminalError) {
        if scriptableAlertsShown.insert("\(terminalChoice.appName).\(failure.alertKey)").inserted {
            Alerts.show(failure.alertText)
        }
    }

    /// Opens a new tab of the scriptable terminal in the repo running the start command, so the tab's
    /// folder is the repo's. When scripting fails, Ghostty falls back to the `.command` launcher; Orca,
    /// which cannot run one, only reports it.
    private func startInScriptable(_ command: String, directory: String, key: String) {
        let starting = "\(key)|\(directory)"
        guard !scriptableStarting.contains(starting) else { return }
        guard let controller = scriptableController() else {
            startingTickets.clear(key)
            return
        }
        let fallsBack = terminalChoice.isGhostty
        scriptableStarting.insert(starting)
        Task { [weak self] in
            let failure = await Task.detached { () -> (any ScriptableTerminalError)? in
                Self.attempt { try controller.openTab(directory: directory, command: command, title: Self.tabTitle(key: key)) }
            }.value
            guard let self else { return }
            scriptableStarting.remove(starting)
            guard let failure else { return }
            reportScriptableFailure(failure)
            if fallsBack {
                terminal()?.open(command)
            } else {
                startingTickets.clear(key)
            }
        }
    }

    /// Runs a scriptable-terminal action, returning its failure.
    private nonisolated static func attempt(_ action: () throws -> Void) -> (any ScriptableTerminalError)? {
        do {
            try action()
            return nil
        } catch let error as any ScriptableTerminalError {
            return error
        } catch {
            return OrcaError.commandFailed("\(error)")
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
    /// The card's session button: for a finished run with a saved report ("Read the report"), the report.
    func openSession(runID: String) {
        afterTerminalResolved { [self] in openSessionNow(runID: runID, showingReport: true) }
    }

    /// The conversation itself, even for a finished run ("Open the session", in the card's menu).
    func openConversation(runID: String) {
        afterTerminalResolved { [self] in openSessionNow(runID: runID, showingReport: false) }
    }

    private func openSessionNow(runID: String, showingReport: Bool) {
        acknowledgeIfDone(runID)
        guard let run = runs.first(where: { $0.id == runID }) else { return }
        let report = RunReport.file(runID: run.id, runsDirectory: paths.runsDirectory)
        if showingReport, RunReport.opensFile(run: run, reportSavedAt: RunReport.modified(report)),
           let text = try? String(contentsOf: report, encoding: .utf8) {
            reportWindows.show(runID: run.id, key: run.key, report: text)
            return
        }
        let action = SessionAction.forOpening(run)
        if config != nil, terminalChoice.isScriptable {
            openInScriptable(run, action: action)
            return
        }
        switch action {
        case .resume, .start:
            resume(runID: runID)
        case .bringToFront:
            terminal()?.activate()
        }
    }

    /// Focuses the run's tab in the scriptable terminal, else opens its session in a new tab. A session
    /// believed ended only reuses a tab titled like Claude Code, never a plain shell; a session with no tab
    /// is resumed in a new one, even when recorded running. `findTab` is false for the explicit "Resume"
    /// and for a run without session, which always open a new tab. A failure is reported once per kind;
    /// then, with Ghostty, a live session just brings Ghostty to the front and anything else goes through
    /// the `.command` launcher. Orca opens its tab in the repo's main checkout, the folder Orca knows (the
    /// command changes to the session's folder itself), and has no fallback.
    private func openInScriptable(_ run: Run, action: SessionAction, findTab: Bool = true) {
        guard !scriptableBusyRuns.contains(run.id) else { return }
        let command: String
        do {
            command = try SessionCommand.resume(run, permissionMode: config?.permissionMode)
        } catch {
            Alerts.show(AlertText(title: "\(run.key) cannot resume", message: "\(error)"))
            return
        }
        guard let controller = scriptableController() else { return }
        let folders = terminalChoice.sessionFolders(SessionLocator.candidateFolders(for: run))
        let directory = terminalChoice.isOrca ? run.repoPath : SessionCommand.resumeDirectory(for: run)
        let fallsBack = terminalChoice.isGhostty
        // With Orca, the tab named after the key is the session even before the run recorded it (a run
        // without session yet, or an explicit Resume): look for it first, so a live session is never doubled.
        let keyNamesTheSession = terminalChoice.keyNamesTheSession
        let searchesTab = keyNamesTheSession || (findTab && action != .start)
        let runID = run.id
        let key = run.key
        let live = action == .bringToFront
        scriptableBusyRuns.insert(run.id)
        Task { [weak self] in
            let failure = await Task.detached { () -> (any ScriptableTerminalError)? in
                Self.attempt {
                    if searchesTab {
                        // The tab list is authoritative: no matching tab means the session is closed.
                        let terminals = try controller.listTerminals()
                        switch action.scriptableOutcome(
                            terminals: terminals, key: key, folders: folders, keyNamesTheSession: keyNamesTheSession
                        ) {
                        case let .focus(terminalID):
                            try controller.focus(terminalID: terminalID)
                            return
                        case .bringToFront:
                            try controller.activate()
                            return
                        case .openNewTab:
                            break
                        }
                    }
                    try controller.openTab(directory: directory, command: command, title: Self.tabTitle(key: key))
                }
            }.value
            guard let self else { return }
            scriptableBusyRuns.remove(runID)
            guard let failure else { return }
            reportScriptableFailure(failure)
            guard fallsBack else { return }
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
        if config != nil, terminalChoice.isScriptable {
            openInScriptable(run, action: .resume, findTab: false)
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

    /// The small line under a ticket to do: "KEY · iOS · Backlog" (`TodoList.context`).
    func todoContext(_ issue: JiraIssue) -> String {
        TodoList.context(of: issue, repos: config?.repos ?? [])
    }

    func release(runID: String) {
        guard releasable.contains(runID), !releasing.contains(runID), let run = runs.first(where: { $0.id == runID })
        else { return }
        let mainBranch = config?.repos.first { $0.name == run.repo }?.mainBranch
        let releaser = Releaser(runner: untimedRunner)
        let checkedOut = run.worktree.flatMap { releaser.checkedOutBranch(worktree: $0) }
        let plan = ReleasePlan.make(
            run: run, runsDirectory: paths.runsDirectory, mainBranch: mainBranch, checkedOutBranch: checkedOut
        )
        guard Alerts.confirmRelease(run, plan: plan) else { return }
        let freed = Releasable.worktreeExists(run) ? RunLine.sizeLabel(bytes: diskUsage[runID]) : nil
        let done = (title: "\(run.key) · \(run.repo) removed", body: freed.map { "\($0) freed" })
        perform(plan, releaser: releaser, forceBranches: false, done: done)
    }

    /// Releases off the main actor, the card reading "Removing…" meanwhile, then notifies `done`: the panel
    /// is closed by then. A branch kept for its unmerged commits can be deleted anyway, once the user chose to.
    private func perform(
        _ plan: ReleasePlan, releaser: Releaser, forceBranches: Bool, done: (title: String, body: String?)
    ) {
        let runID = plan.runID
        releasing.insert(runID)
        Task { [weak self] in
            let failure = await Task.detached { () -> ReleaseError? in
                do throws(ReleaseError) {
                    try releaser.release(plan, forceBranches: forceBranches)
                    return nil
                } catch {
                    return error
                }
            }.value
            guard let self else { return }
            releasing.remove(runID)
            refreshRuns()
            guard let failure else {
                reportWindows.close(runID: runID)
                notifier?.notifyRemoved(title: done.title, body: done.body)
                return
            }
            guard case .branchNotDeleted = failure else {
                Alerts.show(failure.alertText)
                return
            }
            if Alerts.confirm(failure.alertText, button: "Delete Anyway", destructive: true) {
                perform(plan, releaser: releaser, forceBranches: true, done: done)
            }
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

    /// Where Send feedback leads, until the feedback window exists.
    private static let issuesURL = URL(string: "https://github.com/janinjan/ticket-pilot/issues")!

    func sendFeedback() {
        NSWorkspace.shared.open(Self.issuesURL)
    }

    /// Writes `terminal_app` into the config (nil removes it, for "Automatic"), every other key kept.
    func setTerminalApp(_ name: String?) {
        guard name != selectedTerminal else { return }
        editConfig(failure: "The terminal was not changed") { try ConfigEditor.setTerminalApp(name, in: $0) }
        runDoctor()
    }

    /// The config file, with `~` for the home folder.
    var configFilePath: String {
        (paths.configFile.path as NSString).abbreviatingWithTildeInPath
    }

    var configFileExists: Bool {
        FileManager.default.fileExists(atPath: paths.configFile.path)
    }

    func openConfigFile() {
        openInTextEditor(paths.configFile.resolvingSymlinksInPath())
    }

    /// Opens a file in the default text editor: a `.json` file may otherwise open in an IDE.
    private func openInTextEditor(_ file: URL) {
        guard let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) else {
            NSWorkspace.shared.open(file)
            return
        }
        NSWorkspace.shared.open([file], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

    func showConfigFileInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([paths.configFile.resolvingSymlinksInPath()])
    }

    /// Edits the config file in place; false (after an alert titled `failure`) when it could not.
    @discardableResult
    private func editConfig(failure: String, _ edit: (Data) throws -> Data) -> Bool {
        // A symlinked config is edited where it points, not replaced by a plain file.
        let file = paths.configFile.resolvingSymlinksInPath()
        do {
            let data = try Data(contentsOf: file)
            try edit(data).write(to: file, options: .atomic)
            return true
        } catch {
            let detail = switch error {
            case ConfigEditError.invalidJSON: "\(file.path) is not valid JSON."
            case ConfigEditError.notAnObject: "\(file.path) does not hold a JSON object with a jira object."
            case ConfigEditError.invalidName: "This value cannot be saved."
            default: error.localizedDescription
            }
            Alerts.show(AlertText(title: failure, message: detail))
            return false
        }
    }

    /// "Play a sound when TicketPilot needs you", in Settings.
    private(set) var playsSoundState = Notifier.playsSound
    /// "Notifications: allowed" / "not allowed" / "sound off", under Settings' test button.
    private(set) var notificationStatus: String?

    /// Reads whether macOS shows the app's notifications and plays their sound.
    func refreshNotificationStatus() {
        guard notifier != nil else { return }
        Task { [weak self] in
            let permissions = await Notifier.permissions()
            self?.notificationStatus = NotificationStatus.text(
                allowed: permissions.allowed, soundAllowed: permissions.soundAllowed
            )
        }
    }

    /// Posts the test notification; when macOS does not allow the app's notifications, explains how to
    /// allow them, with a button to the Notifications settings.
    func sendTestNotification() {
        guard notifier != nil else { return }
        Task { [weak self] in
            let permissions = await Notifier.permissions()
            self?.notificationStatus = NotificationStatus.text(
                allowed: permissions.allowed, soundAllowed: permissions.soundAllowed
            )
            guard permissions.allowed else {
                if Alerts.confirm(NotificationStatus.howToAllow, button: "Open Notifications Settings") {
                    NSWorkspace.shared.open(NotificationStatus.settingsURL)
                }
                return
            }
            self?.notifier?.notifyTest()
        }
    }

    /// Two-way properties for `$model.…` bindings in Settings: no closure-based `Binding` to cross isolation.
    var openAtLogin: Bool {
        get { openAtLoginState }
        set { setOpenAtLogin(newValue) }
    }

    var playsSound: Bool {
        get { playsSoundState }
        set { setPlaysSound(newValue) }
    }

    var terminalChoiceName: String? {
        get { selectedTerminal }
        set { setTerminalApp(newValue) }
    }

    func setPlaysSound(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Notifier.soundKey)
        playsSoundState = enabled
    }

    func setOpenAtLogin(_ enabled: Bool) {
        guard hasBundle else { return }
        do {
            try LoginItem.set(enabled)
        } catch {
            Alerts.show(AlertText(title: "Open at login was not changed", message: error.localizedDescription))
        }
        openAtLoginState = LoginItem.isEnabled
    }

    /// Does what the setup button offers for the setup problem.
    func fixSetupProblem() {
        guard let setupProblem else { return }
        switch setupProblem.action {
        case let .openURL(url): NSWorkspace.shared.open(url)
        case let .copyFix(check): copyFix(of: check)
        case .connectAtlassian:
            if configProblem == .missing { completeJiraSetup(signInIfNeeded: true) } else { connectAtlassian() }
        case let .explain(text): Alerts.show(text)
        case .checkAgain: runDoctor()
        case let .installPlugin(state): installPlugin(state)
        case .addRepository: addRepository()
        }
    }

    // MARK: - Guided setup

    /// With a stored Atlassian sign-in: reads the account and writes `jira.site` where it is missing (creating the config), asking which site when the account has several. Without one,
    /// opens the sign-in when `signInIfNeeded` (a click), else does nothing (a launch).
    private func completeJiraSetup(signInIfNeeded: Bool) {
        guard !settingUpJira else { return }
        settingUpJira = true
        let auth = atlassianAuth
        Task { [weak self] in
            let connected = (try? await auth.isConnected()) == true
            var account: Result<AtlassianAccount, JiraError>?
            if connected {
                do throws(JiraError) {
                    account = .success(try await MCPJiraClient.account(
                        tools: MCPClient(url: auth.server, tokens: auth, clientVersion: Self.version)
                    ))
                } catch {
                    account = .failure(error)
                }
            }
            guard let self else { return }
            settingUpJira = false
            hasAtlassianSignIn = connected
            switch account {
            case nil:
                if signInIfNeeded { connectAtlassian() }
            case let .failure(error):
                Alerts.show(AlertText(title: "Jira was not set up", message: "\(error)"))
            case let .success(account):
                let site: URL
                switch account.siteChoice {
                case .noSite:
                    noJiraSite = true
                    return
                case let .only(only):
                    site = only
                case let .ask(sites):
                    guard let chosen = Alerts.chooseSite(sites) else { return }
                    site = chosen
                }
                noJiraSite = false
                if writeJira(site: site) { runDoctor() }
            }
        }
    }

    /// Fills the Jira site of the config, creating the file (and its folder) when there is none.
    private func writeJira(site: URL) -> Bool {
        let file = paths.configFile.resolvingSymlinksInPath()
        do {
            let existing = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
            let data = try ConfigEditor.fillJira(site: site, in: existing)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return true
        } catch {
            Alerts.show(AlertText(title: "The config was not saved", message: error.localizedDescription))
            return false
        }
    }

    /// Lists the checkouts of the folder that holds the repos (the one of the repos already added, else
    /// ~/Developer, else one the user picks), to tick and add together.
    func addRepository() {
        guard let folder = defaultReposFolder() ?? pickReposFolder() else { return }
        addRepositories(in: folder)
    }

    private func addRepositories(in folder: URL) {
        guard let config else { return }
        let runner = untimedRunner
        let added = config.repos.map(\.path)
        // Opened now, on the click: a window opened once the search is over would stay behind the others.
        addRepositoriesWindow.showSearching(folder: folder)
        Task { [weak self] in
            let found = await Task.detached { RepoDetector.scan(folder: folder, runner: runner, excluding: added) }.value
            guard let self, let config = self.config, addRepositoriesWindow.isOpen else { return }
            addRepositoriesWindow.show(
                folder: folder, proposals: found, existing: config.repos.map(\.name),
                existingPlatforms: Set(config.repos.compactMap(RepoName.platform(of:))),
                onAdd: { [weak self] entries in self?.add(entries) },
                onOtherFolder: { [weak self] in
                    guard let self, let other = pickReposFolder() else { return }
                    addRepositories(in: other)
                }
            )
        }
    }

    private func add(_ entries: [RepoEntry]) {
        let saved = editConfig(failure: "The repositories were not added") { data in
            try entries.reduce(data) { data, entry in try ConfigEditor.addRepo(entry, in: data) }
        }
        guard saved else { return }
        addRepositoriesWindow.close()
        runDoctor()
    }

    private func defaultReposFolder() -> URL? {
        if let first = config?.repos.first {
            let parent = URL(fileURLWithPath: (first.path as NSString).expandingTildeInPath).deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: parent.path) { return parent }
        }
        let developer = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer")
        return FileManager.default.fileExists(atPath: developer.path) ? developer : nil
    }

    private func pickReposFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder that holds your repositories, or one repository."
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Removes a repository from the config (never its folder); refused while one of its runs is listed.
    func removeRepository(named name: String) {
        let display = RepoName.display(name)
        if runs.contains(where: { $0.repo == name }) {
            Alerts.show(AlertText(title: "\(display) has runs", message: "Remove its worktrees first."))
            return
        }
        guard Alerts.confirm(
            AlertText(title: "Remove \(display) from TicketPilot?", message: "Its folder stays on your Mac: only its entry in the config is removed."),
            button: "Remove"
        ) else { return }
        if editConfig(failure: "The repository was not removed", { try ConfigEditor.removeRepo(named: name, in: $0) }) {
            runDoctor()
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
            let version = Doctor.pluginVersion(manifest: Doctor.bundledPluginManifest(resources: Bundle.main.resourceURL))
            guard Alerts.confirm(PluginInstaller.confirmation(commands, version: version), button: PluginInstaller.confirmButton(commands)) else {
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
            case .success:
                Alerts.show(PluginInstaller.success(commands, version: version))
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

    // MARK: - Atlassian sign-in

    /// Opens the Atlassian sign-in in the browser and waits (five minutes at most) for it to come back to
    /// TicketPilot's loopback listener; then checks the setup again and polls.
    func connectAtlassian() {
        guard !signingIn else { return }
        signingIn = true
        let id = UUID()
        signInID = id
        let auth = atlassianAuth
        signInTask = Task { [weak self] in
            do throws(MCPError) {
                let signIn = try await auth.beginSignIn()
                guard let self, signInID == id, !Task.isCancelled else {
                    signIn.cancel()
                    return
                }
                pendingSignIn = signIn
                NSWorkspace.shared.open(signIn.authorizeURL)
                _ = try await auth.completeSignIn(signIn)
                guard signInID == id else { return }
                finishSignIn()
                hasAtlassianSignIn = true
                jiraSetupTried = false
                runDoctor()
            } catch {
                // A cancelled sign-in was already ended by `cancelSignIn`, or replaced by a newer one.
                guard let self, signInID == id else { return }
                finishSignIn()
                if error != .cancelled {
                    Alerts.show(AlertText(title: "Jira was not connected", message: error.message))
                }
            }
        }
    }

    func cancelSignIn() {
        pendingSignIn?.cancel()
        signInTask?.cancel()
        finishSignIn()
    }

    private func finishSignIn() {
        signingIn = false
        pendingSignIn = nil
        signInTask = nil
        signInID = nil
    }

    /// Forgets the Atlassian sign-in (deletes its Keychain item) and checks the setup again.
    func disconnectJira() {
        cancelSignIn()
        let auth = atlassianAuth
        Task { [weak self] in
            await auth.disconnect()
            self?.jiraAccount = nil
            self?.noJiraSite = false
            self?.hasAtlassianSignIn = false
            self?.runDoctor()
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

/// What a commit count was made for.
private struct CommitCountKey: Equatable {
    var updatedAt: Date
    var mainBranch: String
    var mainHead: String?
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

