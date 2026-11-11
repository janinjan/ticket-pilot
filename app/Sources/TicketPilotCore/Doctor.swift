import Foundation

public struct HealthCheck: Equatable, Identifiable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case claudeCLI, plugin, jiraToken, jiraReachable, mcp, repoPaths, diskSpace

        public var title: String {
            switch self {
            case .claudeCLI: "Claude Code"
            case .plugin: "Plugin"
            case .jiraToken: "Jira token"
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
    /// True when only a new Jira token can fix this check (missing, or refused by Jira); false
    /// when the Keychain itself refused access.
    public var needsToken: Bool

    public init(
        id: Kind,
        ok: Bool,
        detail: String,
        fix: String? = nil,
        blocksStart: Bool = false,
        blockedRepos: [String] = [],
        needsToken: Bool = false
    ) {
        self.id = id
        self.ok = ok
        self.detail = detail
        self.fix = fix
        self.blocksStart = blocksStart
        self.blockedRepos = blockedRepos
        self.needsToken = needsToken
    }
}

extension Array where Element == HealthCheck {
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

    public var firstProblem: HealthCheck? {
        first { !$0.ok }
    }

    /// The health line of the menu: a config error first, then "Checking…" until the doctor
    /// has answered, then the first failed check, else "All good".
    public func summary(configError: String?) -> String {
        if let configError { return "Config: \(configError)" }
        if isEmpty { return "Checking…" }
        return firstProblem.map { "\($0.id.title): \($0.detail)" } ?? "All good"
    }

    /// The Jira token must be entered: missing, or refused by Jira. Not when Keychain access failed.
    public var needsToken: Bool {
        contains { !$0.ok && $0.needsToken }
    }

    public var hasProblem: Bool {
        contains { !$0.ok }
    }
}

/// Checks that everything a run needs is in place. Never logs or returns the Jira token.
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
        claudeSearchPaths: [String]? = nil
    ) {
        self.config = config
        self.home = home
        self.runner = runner
        self.jira = jira
        self.tokenLookup = tokenLookup
        self.freeBytes = freeBytes
        self.claudeSearchPaths = claudeSearchPaths ?? Self.defaultClaudeSearchPaths(home: home)
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
        if let version = installedPluginVersion() {
            return HealthCheck(id: .plugin, ok: true, detail: version)
        }
        return HealthCheck(
            id: .plugin,
            ok: false,
            detail: "The ticket-pilot plugin is not installed",
            fix: "claude plugin install \(Self.pluginKey)",
            blocksStart: true
        )
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
            let (detail, fix) = switch error {
            case .unreachable: ("Jira is unreachable", "Check the network or the VPN")
            case let .http(status): ("Jira answered unexpectedly", "Check jira.site in the config (HTTP \(status))")
            case .invalidResponse, .unauthorized: ("Jira answered unexpectedly", "Check jira.site in the config")
            }
            return (
                tokenFound,
                HealthCheck(id: .jiraReachable, ok: false, detail: detail, fix: fix, blocksStart: true)
            )
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
