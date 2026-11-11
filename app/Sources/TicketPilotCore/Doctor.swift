import Foundation

public struct HealthCheck: Equatable, Identifiable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case claudeCLI, plugin, jiraToken, jiraSignIn, jiraReachable, mcp, repoPaths, diskSpace

        public var title: String {
            switch self {
            case .claudeCLI: "Claude Code"
            case .plugin: "Plugin"
            case .jiraToken: "Jira token"
            case .jiraSignIn: "Jira sign-in"
            case .jiraReachable: "Jira"
            case .mcp: "MCP servers"
            case .repoPaths: "Repos"
            case .diskSpace: "Disk space"
            }
        }
    }

    public var id: Kind
    public var ok: Bool
    public var detail: String
    public var fix: String?
    public var blocksStart: Bool
    public var blockedRepos: [String]
    /// True when only a new Jira token (or a new Atlassian sign-in) can fix this check (missing, or
    /// refused by Jira); false when the Keychain itself refused access.
    public var needsToken: Bool
    /// For the Atlassian sign-in: Atlassian refused with its own explanation (`detail`), which a new
    /// sign-in would not change (an administrator block, for example).
    public var refusedByServer: Bool
    /// For the plugin check: the installed plugin compared with the copy the app carries.
    public var pluginState: PluginState?

    public init(
        id: Kind,
        ok: Bool,
        detail: String,
        fix: String? = nil,
        blocksStart: Bool = false,
        blockedRepos: [String] = [],
        needsToken: Bool = false,
        refusedByServer: Bool = false,
        pluginState: PluginState? = nil
    ) {
        self.id = id
        self.ok = ok
        self.detail = detail
        self.fix = fix
        self.blocksStart = blocksStart
        self.blockedRepos = blockedRepos
        self.needsToken = needsToken
        self.refusedByServer = refusedByServer
        self.pluginState = pluginState
    }
}

extension Array where Element == HealthCheck {
    /// The `claude` executable the doctor found, if any.
    public var claudePath: String? {
        first { $0.id == .claudeCLI && $0.ok }?.detail
    }

    /// A repo can start a run when no check blocks every start and none blocks that repo.
    public func canStart(repo: String) -> Bool {
        startBlocker(repo: repo) == nil
    }

    /// The first failed check that prevents starting a run on `repo`.
    public func startBlocker(repo: String) -> HealthCheck? {
        first { !$0.ok && ($0.blocksStart || $0.blockedRepos.contains(repo)) }
    }

    /// The first failed check that prevents starting a ticket by `route`: for a choice window,
    /// only a check that blocks every repo, since the window lets the user pick another one.
    public func startBlocker(for route: StartRoute) -> HealthCheck? {
        switch route {
        case let .direct(repo): startBlocker(repo: repo.name)
        case .pick: first { !$0.ok && $0.blocksStart }
        }
    }
}

/// Checks that everything a run needs is in place. Never logs or returns the Jira token or the Atlassian
/// sign-in. `tokenLookup` reads the API token, or with `jira.auth` `mcp` the stored sign-in
/// (`KeychainError.notFound` when there is none).
public struct Doctor: Sendable {
    private static let pluginKey = "ticket-pilot@ticket-pilot"
    private static let lowDiskBytes: Int64 = 10 * 1024 * 1024 * 1024
    private static let mcpNames = ["atlassian", "figma"]

    private let config: AppConfig
    private let home: URL
    private let runner: ProcessRunning
    private let jira: JiraSearching?
    private let tokenLookup: @Sendable () throws -> String
    private let freeBytes: @Sendable () -> Int64?
    private let claudeSearchPaths: [String]
    private let bundledPluginManifest: URL?

    /// An app started from the Finder has no shell `PATH`, so `claude` is looked up at its usual locations.
    public static func defaultClaudeSearchPaths(home: URL) -> [String] {
        [
            home.appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
    }

    public init(
        config: AppConfig,
        home: URL,
        runner: ProcessRunning,
        jira: JiraSearching?,
        tokenLookup: @escaping @Sendable () throws -> String,
        freeBytes: @escaping @Sendable () -> Int64?,
        claudeSearchPaths: [String]? = nil,
        bundledPluginManifest: URL? = nil
    ) {
        self.config = config
        self.home = home
        self.runner = runner
        self.jira = jira
        self.tokenLookup = tokenLookup
        self.freeBytes = freeBytes
        self.claudeSearchPaths = claudeSearchPaths ?? Self.defaultClaudeSearchPaths(home: home)
        self.bundledPluginManifest = bundledPluginManifest
    }

    /// The manifest of the plugin copy inside the app bundle (`Resources/plugin`).
    public static func bundledPluginManifest(resources: URL?) -> URL? {
        resources?.appendingPathComponent("plugin/.claude-plugin/plugin.json")
    }

    public func run() async -> [HealthCheck] {
        let claudePath = claudeSearchPaths.first {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory)
                && !isDirectory.boolValue
                && FileManager.default.isExecutableFile(atPath: $0)
        }
        let jiraChecks = await checkJira()
        return [
            checkClaude(path: claudePath),
            checkPlugin(),
            jiraChecks.token,
            jiraChecks.reachable,
            checkMCP(claudePath: claudePath),
            checkRepoPaths(),
            checkDiskSpace(),
        ]
    }

    // MARK: - Checks

    private func checkClaude(path: String?) -> HealthCheck {
        if let path {
            return HealthCheck(id: .claudeCLI, ok: true, detail: path)
        }
        return HealthCheck(
            id: .claudeCLI,
            ok: false,
            detail: "Claude Code not found",
            fix: "Install Claude Code: https://docs.claude.com/claude-code",
            blocksStart: true
        )
    }

    private func checkPlugin() -> HealthCheck {
        let installed = installedPluginVersion()
        let bundled = bundledPluginVersion()
        let state = PluginState.compare(installed: installed, bundled: bundled)
        let detail = "\(installed.map { "installed \($0)" } ?? "not installed") · bundled \(bundled ?? "none")"
        switch state {
        case .missing:
            return HealthCheck(
                id: .plugin,
                ok: false,
                detail: detail,
                fix: "claude plugin install \(Self.pluginKey)",
                blocksStart: true,
                pluginState: state
            )
        case .outdated:
            // The installed plugin still runs: an update never blocks a start.
            return HealthCheck(id: .plugin, ok: false, detail: detail, pluginState: state)
        case .current, .newerThanBundled, .unknown:
            return HealthCheck(id: .plugin, ok: true, detail: detail, pluginState: state)
        }
    }

    private func bundledPluginVersion() -> String? {
        guard let bundledPluginManifest,
              let data = try? Data(contentsOf: bundledPluginManifest),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root["version"] as? String
    }

    private func installedPluginVersion() -> String? {
        let url = home.appendingPathComponent(".claude/plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any],
              let entries = plugins[Self.pluginKey] as? [[String: Any]],
              let first = entries.first
        else { return nil }
        return first["version"] as? String ?? "unknown"
    }

    private func checkJira() async -> (token: HealthCheck, reachable: HealthCheck) {
        switch config.jira.auth {
        case .apiToken: await checkJiraToken()
        case .mcp: await checkJiraSignIn()
        }
    }

    private func checkJiraSignIn() async -> (token: HealthCheck, reachable: HealthCheck) {
        let site = config.jira.site.absoluteString
        do {
            _ = try tokenLookup()
        } catch {
            let missing = if case let KeychainError.unexpected(status) = error {
                HealthCheck(
                    id: .jiraSignIn,
                    ok: false,
                    detail: "Keychain access was refused or failed (status \(status))",
                    fix: "Allow TicketPilot in the Keychain prompt, then choose Check again",
                    blocksStart: true
                )
            } else {
                HealthCheck(id: .jiraSignIn, ok: false, detail: "Not connected to Atlassian", blocksStart: true, needsToken: true)
            }
            return (missing, HealthCheck(id: .jiraReachable, ok: false, detail: "not checked: not connected"))
        }
        let connected = HealthCheck(id: .jiraSignIn, ok: true, detail: "Connected via Atlassian MCP")
        guard let jira else {
            return (connected, HealthCheck(id: .jiraReachable, ok: false, detail: "not checked: no Jira client"))
        }
        do {
            try await jira.checkCredentials()
            return (connected, HealthCheck(id: .jiraReachable, ok: true, detail: site))
        } catch .unauthorized, .notConnected {
            return (
                HealthCheck(
                    id: .jiraSignIn, ok: false, detail: "Atlassian refused the sign-in", blocksStart: true, needsToken: true
                ),
                HealthCheck(id: .jiraReachable, ok: true, detail: site)
            )
        } catch let .keychain(status) {
            return (
                HealthCheck(
                    id: .jiraSignIn,
                    ok: false,
                    detail: "Keychain access was refused or failed (status \(status))",
                    fix: "Allow TicketPilot in the Keychain prompt, then choose Check again",
                    blocksStart: true
                ),
                HealthCheck(id: .jiraReachable, ok: false, detail: "not checked: Keychain refused")
            )
        } catch let .refused(message) {
            return (
                HealthCheck(
                    id: .jiraSignIn,
                    ok: false,
                    detail: message,
                    fix: "Ask your Atlassian administrator to allow the Atlassian MCP server, or use an API token instead (Settings › Jira).",
                    blocksStart: true,
                    refusedByServer: true
                ),
                HealthCheck(id: .jiraReachable, ok: true, detail: site)
            )
        } catch {
            return (connected, unreachable(error))
        }
    }

    private func unreachable(_ error: JiraError) -> HealthCheck {
        let (detail, fix) = switch error {
        case .unreachable: ("Jira is unreachable", "Check the network or the VPN")
        case let .http(status): ("Jira answered unexpectedly", "Check jira.site in the config (HTTP \(status))")
        case let .refused(message), let .serverError(message): (message, "Check jira.site in the config")
        case let .keychain(status): ("Keychain access was refused or failed (status \(status))", "Allow TicketPilot in the Keychain prompt")
        case .invalidResponse, .unauthorized, .notConnected: ("Jira answered unexpectedly", "Check jira.site in the config")
        }
        return HealthCheck(id: .jiraReachable, ok: false, detail: detail, fix: fix, blocksStart: true)
    }

    private func checkJiraToken() async -> (token: HealthCheck, reachable: HealthCheck) {
        let service = config.jira.keychainService
        do {
            _ = try tokenLookup()
        } catch {
            let missing = if case let KeychainError.unexpected(status) = error {
                HealthCheck(
                    id: .jiraToken,
                    ok: false,
                    detail: "Keychain access was refused or failed (status \(status))",
                    fix: "Allow TicketPilot in the Keychain prompt, then choose Check again",
                    blocksStart: true
                )
            } else {
                HealthCheck(
                    id: .jiraToken,
                    ok: false,
                    detail: "No Jira token in the Keychain",
                    fix: #"security add-generic-password -s "\#(service)" -a "$USER" -w"#,
                    blocksStart: true,
                    needsToken: true
                )
            }
            return (missing, HealthCheck(id: .jiraReachable, ok: false, detail: "not checked: no Jira token"))
        }
        let tokenFound = HealthCheck(id: .jiraToken, ok: true, detail: "Token found in the Keychain")
        guard let jira else {
            return (tokenFound, HealthCheck(id: .jiraReachable, ok: false, detail: "not checked: no Jira client"))
        }
        do {
            try await jira.checkCredentials()
            return (tokenFound, HealthCheck(id: .jiraReachable, ok: true, detail: config.jira.site.absoluteString))
        } catch .unauthorized {
            return (
                HealthCheck(
                    id: .jiraToken,
                    ok: false,
                    detail: "Jira refused the token",
                    fix: "Create a new API token and store it again in the Keychain service \"\(service)\"",
                    blocksStart: true,
                    needsToken: true
                ),
                HealthCheck(id: .jiraReachable, ok: true, detail: config.jira.site.absoluteString)
            )
        } catch {
            return (tokenFound, unreachable(error))
        }
    }

    private func checkMCP(claudePath: String?) -> HealthCheck {
        guard let claudePath else {
            return HealthCheck(id: .mcp, ok: false, detail: "claude not found")
        }
        guard let result = try? runner.run(claudePath, ["mcp", "list"], currentDirectory: nil), result.status == 0 else {
            return HealthCheck(id: .mcp, ok: false, detail: "could not list the MCP servers")
        }
        var concerned: [String] = []
        var sawServer = false
        for line in result.output.split(whereSeparator: \.isNewline) {
            let lowercased = line.lowercased()
            guard Self.mcpNames.contains(where: lowercased.contains) else { continue }
            sawServer = true
            if line.range(of: #"\bConnected\b"#, options: .regularExpression) == nil {
                concerned.append(line.split(separator: ":", maxSplits: 1).first.map(String.init) ?? String(line))
            }
        }
        if !sawServer {
            return HealthCheck(id: .mcp, ok: true, detail: "not configured")
        }
        if concerned.isEmpty {
            return HealthCheck(id: .mcp, ok: true, detail: "Atlassian and Figma servers connected")
        }
        return HealthCheck(id: .mcp, ok: false, detail: "Not connected: " + concerned.joined(separator: ", "))
    }

    private func checkRepoPaths() -> HealthCheck {
        let missing = config.repos.filter {
            !FileManager.default.fileExists(atPath: ($0.path as NSString).expandingTildeInPath)
        }.map(\.name)
        if missing.isEmpty {
            return HealthCheck(id: .repoPaths, ok: true, detail: "All repo paths exist")
        }
        return HealthCheck(
            id: .repoPaths,
            ok: false,
            detail: "Path not found for: " + missing.joined(separator: ", "),
            blockedRepos: missing
        )
    }

    private func checkDiskSpace() -> HealthCheck {
        guard let free = freeBytes() else {
            return HealthCheck(id: .diskSpace, ok: true, detail: "unknown")
        }
        let gigabytes = String(format: "%.1f", Double(free) / 1_073_741_824)
        if free < Self.lowDiskBytes {
            return HealthCheck(id: .diskSpace, ok: false, detail: "Only \(gigabytes) GB free")
        }
        return HealthCheck(id: .diskSpace, ok: true, detail: "\(gigabytes) GB free")
    }
}
