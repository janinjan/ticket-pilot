import Foundation

/// A repository offered for a ticket in the choice window.
public struct RepoChoice: Equatable, Identifiable, Sendable {
    public var repo: RepoConfig
    public var matched: Bool
    /// Set when a run of this ticket already exists on this repo: the window offers "Resume".
    public var existingRunID: String?

    public var id: String { repo.name }

    public init(repo: RepoConfig, matched: Bool, existingRunID: String?) {
        self.repo = repo
        self.matched = matched
        self.existingRunID = existingRunID
    }
}

public enum RepoMatcher {
    /// Repos whose rules match the ticket, in config order.
    public static func repos(for issue: JiraIssue, in repos: [RepoConfig]) -> [RepoConfig] {
        repos.filter { matches(issue, $0.match) }
    }

    /// Every configured repo: matching ones first, then the others, each in config order.
    public static func choices(for issue: JiraIssue, repos: [RepoConfig], runs: [Run]) -> [RepoChoice] {
        let matchedNames = Set(Self.repos(for: issue, in: repos).map(\.name))
        let all = repos.map { repo in
            RepoChoice(
                repo: repo,
                matched: matchedNames.contains(repo.name),
                existingRunID: runs.first { $0.key == issue.key && $0.repo == repo.name }?.id
            )
        }
        return all.filter(\.matched) + all.filter { !$0.matched }
    }

    private static func matches(_ issue: JiraIssue, _ rules: MatchRules) -> Bool {
        let titleMatch = rules.titlePrefixes.contains { prefix in
            !prefix.isEmpty && issue.summary.localizedCaseInsensitiveContains(prefix)
        }
        return titleMatch
            || containsIgnoringCase(issue.labels, in: rules.labels)
            || containsIgnoringCase(issue.components, in: rules.components)
    }

    private static func containsIgnoringCase(_ values: [String], in wanted: [String]) -> Bool {
        let wantedLowercased = Set(wanted.map { $0.lowercased() })
        return values.contains { wantedLowercased.contains($0.lowercased()) }
    }
}

/// How a click on Start proceeds for a ticket.
public enum StartRoute: Equatable, Sendable {
    /// A single matching repo without a run: start there at once.
    case direct(RepoConfig)
    /// Otherwise the choice window opens.
    case pick([RepoChoice])

    public static func make(choices: [RepoChoice]) -> StartRoute {
        let matched = choices.filter(\.matched)
        if matched.count == 1, let only = matched.first, only.existingRunID == nil {
            return .direct(only.repo)
        }
        return .pick(choices)
    }

    /// Repos ticked when the choice window opens: the matching ones that can start.
    public static func initialSelection(_ choices: [RepoChoice], health: [HealthCheck]) -> Set<String> {
        Set(choices.filter { $0.matched && health.canStart(repo: $0.repo.name) }.map(\.id))
    }
}
