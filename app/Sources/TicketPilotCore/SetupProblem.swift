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
    }

    /// The button that fixes it ("Connect Jira…").
    public var title: String
    /// A calm sentence saying what is missing, for the panel's headline ("Jira isn't connected yet").
    public var headline: String
    public var action: Action

    public init(title: String, headline: String, action: Action) {
        self.title = title
        self.headline = headline
        self.action = action
    }

    static let claudeCodeURL = URL(string: "https://docs.claude.com/claude-code")!

    /// In order: a config error, Claude Code missing, the plugin missing, the Jira token to enter, the
    /// Keychain refusing access, Jira unreachable (or failing to answer the poll), a repo path missing.
    /// `jiraFailing` only counts once the checks are in, so a missing token is not shown as unreachable first.
    /// The other failed checks (MCP servers, disk space) are only warnings: they stay in Diagnostics.
    public static func first(in checks: [HealthCheck], configError: String? = nil, jiraFailing: Bool = false) -> SetupProblem? {
        if let configError {
            return SetupProblem(
                title: "Fix the config…",
                headline: "The config needs a fix",
                action: .explain(AlertText(title: "Config", message: configError))
            )
        }
        func failed(_ kind: HealthCheck.Kind) -> HealthCheck? {
            checks.first { $0.id == kind && !$0.ok }
        }
        if failed(.claudeCLI) != nil {
            return SetupProblem(
                title: "Install Claude Code…", headline: "Claude Code isn't installed yet", action: .openURL(claudeCodeURL)
            )
        }
        if let plugin = failed(.plugin) {
            return SetupProblem(
                title: "Install the ticket-pilot plugin…",
                headline: "The ticket-pilot plugin isn't installed yet",
                action: .copyFix(plugin)
            )
        }
        if let token = failed(.jiraToken) {
            if token.needsToken {
                return SetupProblem(title: "Connect Jira…", headline: "Jira isn't connected yet", action: .setJiraToken)
            }
            let message = [token.detail, token.fix].compactMap { $0 }.joined(separator: "\n\n")
            return SetupProblem(
                title: "Allow Keychain access…",
                headline: "The Jira token can't be read",
                action: .explain(AlertText(title: "Keychain access", message: message))
            )
        }
        if failed(.jiraReachable) != nil || (jiraFailing && !checks.isEmpty) {
            return SetupProblem(
                title: "Jira unreachable — check the network",
                headline: "Jira can't be reached right now",
                action: .checkAgain
            )
        }
        if let repos = failed(.repoPaths) {
            return SetupProblem(
                title: "Repository not found: \(repos.blockedRepos.joined(separator: ", "))…",
                headline: repos.blockedRepos.count == 1 ? "A repository wasn't found" : "Some repositories weren't found",
                action: .explain(AlertText(
                    title: "Repository not found",
                    message: repos.detail + "\n\nCorrect the repo path in your config, then choose Check again."
                ))
            )
        }
        return nil
    }
}
