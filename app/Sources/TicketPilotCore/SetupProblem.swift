import Foundation

/// The one setup problem the panel offers to fix, with the action that fixes it.
public struct SetupProblem: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case openURL(URL)
        /// Copies the check's fix command.
        case copyFix(HealthCheck)
        /// Asks for the Jira token.
        case setJiraToken
        /// Signs in to Atlassian in the browser, for the Atlassian MCP server.
        case connectAtlassian
        /// Shows what is wrong and how to fix it.
        case explain(AlertText)
        /// Runs the setup check again.
        case checkAgain
        /// Runs the setup check again after the Keychain refused access: if it still does, the next
        /// problem is `resetJiraSignIn`.
        case recheckKeychain
        /// Deletes the app's Jira sign-in from the Keychain (the API token, or the Atlassian sign-in), then
        /// connects Jira again.
        case resetJiraSignIn(JiraAuth)
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

    /// In order: a config error, Claude Code missing, the plugin missing, the Jira token to enter (or the
    /// Atlassian sign-in to make, or Atlassian's refusal to explain), the Keychain refusing access, Jira unreachable (or failing to answer the poll), a repo path missing, an
    /// older plugin than the one the app carries (it still runs, so the update comes last).
    /// `jiraFailing` only counts once the checks are in, so a missing token is not shown as unreachable first.
    /// The other failed checks (MCP servers, disk space) are only warnings: they stay in Diagnostics.
    /// A Keychain refusal is checked again first (the item may be gone or allowed by now); once
    /// `keychainRechecked` and still refused, the fix is to reset the Jira sign-in.
    public static func first(
        in checks: [HealthCheck], configError: String? = nil, jiraFailing: Bool = false, keychainRechecked: Bool = false
    ) -> SetupProblem? {
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
            return keychainRefused(reading: "your Jira token", auth: .apiToken, rechecked: keychainRechecked)
        }
        if let signIn = failed(.jiraSignIn) {
            if signIn.needsToken {
                return SetupProblem(title: "Connect Jira…", explanation: "Connect Jira to see your tickets here.", action: .connectAtlassian)
            }
            let message = [signIn.detail, signIn.fix].compactMap { $0 }.joined(separator: "\n\n")
            if signIn.refusedByServer {
                return SetupProblem(
                    title: "See why Jira refused…",
                    explanation: "Atlassian refused the connection to Jira.",
                    action: .explain(AlertText(title: "Atlassian refused the connection", message: message))
                )
            }
            return keychainRefused(reading: "your Atlassian sign-in", auth: .mcp, rechecked: keychainRechecked)
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

    private static func keychainRefused(reading item: String, auth: JiraAuth, rechecked: Bool) -> SetupProblem {
        guard rechecked else {
            return SetupProblem(
                title: "Check again",
                explanation: "TicketPilot couldn't read \(item) from the Keychain. It may work now.",
                action: .recheckKeychain
            )
        }
        return SetupProblem(
            title: "Reset Jira sign-in…",
            explanation: "The Keychain still refuses access. Reset the Jira sign-in, then connect Jira again.",
            action: .resetJiraSignIn(auth)
        )
    }
}
