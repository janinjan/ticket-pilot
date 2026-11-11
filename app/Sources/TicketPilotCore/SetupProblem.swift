import Foundation

/// The one setup problem the panel offers to fix, with the action that fixes it.
public struct SetupProblem: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case openURL(URL)
        /// Copies the check's fix command.
        case copyFix(HealthCheck)
        /// Asks for the Jira token.
        case setJiraToken
        /// Shows what is wrong and how to fix it.
        case explain(AlertText)
        /// Runs the setup check again.
        case checkAgain
        /// Installs or updates the Claude Code plugin the app carries.
        case installPlugin(PluginState)
    }

    /// The button that fixes it ("Connect Jira…").
    public var title: String
    /// Why the panel says "Almost there!", and what the button gets ("Connect Jira to see your tickets here.").
    public var explanation: String
    public var action: Action

    public init(title: String, explanation: String, action: Action) {
        self.title = title
        self.explanation = explanation
        self.action = action
    }

    /// The panel's button: the title with an arrow instead of an ellipsis ("Connect Jira →").
    public var buttonTitle: String {
        (title.hasSuffix("…") ? String(title.dropLast()) : title) + " →"
    }

    static let claudeCodeURL = URL(string: "https://docs.claude.com/claude-code")!

    /// In order: a config error, Claude Code missing, the plugin missing, the Jira token to enter, the
    /// Keychain refusing access, Jira unreachable (or failing to answer the poll), a repo path missing, an
    /// older plugin than the one the app carries (it still runs, so the update comes last).
    /// `jiraFailing` only counts once the checks are in, so a missing token is not shown as unreachable first.
    /// The other failed checks (MCP servers, disk space) are only warnings: they stay in Diagnostics.
    public static func first(in checks: [HealthCheck], configError: String? = nil, jiraFailing: Bool = false) -> SetupProblem? {
        if let configError {
            return SetupProblem(
                title: "Fix the config…",
                explanation: "Fix your config to get started.",
                action: .explain(AlertText(title: "Config", message: configError))
            )
        }
        func failed(_ kind: HealthCheck.Kind) -> HealthCheck? {
            checks.first { $0.id == kind && !$0.ok }
        }
        if failed(.claudeCLI) != nil {
            return SetupProblem(
                title: "Install Claude Code…", explanation: "Install Claude Code to start a ticket.", action: .openURL(claudeCodeURL)
            )
        }
        let plugin = failed(.plugin)?.pluginState
        if plugin == .missing {
            return SetupProblem(
                title: "Install the Claude Code plugin…",
                explanation: "Install the Claude Code plugin to start a ticket.",
                action: .installPlugin(.missing)
            )
        }
        if let token = failed(.jiraToken) {
            if token.needsToken {
                return SetupProblem(title: "Connect Jira…", explanation: "Connect Jira to see your tickets here.", action: .setJiraToken)
            }
            let message = [token.detail, token.fix].compactMap { $0 }.joined(separator: "\n\n")
            return SetupProblem(
                title: "Allow Keychain access…",
                explanation: "Allow Keychain access so TicketPilot can read your Jira token.",
                action: .explain(AlertText(title: "Keychain access", message: message))
            )
        }
        if failed(.jiraReachable) != nil || (jiraFailing && !checks.isEmpty) {
            return SetupProblem(
                title: "Check again",
                explanation: "Jira can't be reached right now. Check your network.",
                action: .checkAgain
            )
        }
        if let repos = failed(.repoPaths) {
            return SetupProblem(
                title: "Repository not found: \(repos.blockedRepos.joined(separator: ", "))…",
                explanation: repos.blockedRepos.count == 1
                    ? "A repository wasn't found. Check its path in your config."
                    : "Some repositories weren't found. Check their paths in your config.",
                action: .explain(AlertText(
                    title: "Repository not found",
                    message: repos.detail + "\n\nCorrect the repo path in your config, then choose Check again."
                ))
            )
        }
        if let plugin, case let .outdated(installed, bundled) = plugin {
            return SetupProblem(
                title: "Update the Claude Code plugin (\(installed) → \(bundled))…",
                explanation: "A newer Claude Code plugin is ready to install.",
                action: .installPlugin(plugin)
            )
        }
        return nil
    }
}
