/// Open tickets assigned to the user: in progress (a run released before the ticket is done), then still
/// to do, those in a "ready" status first. A ticket with a run is left out: its run card stands for it.
public struct TodoList: Equatable, Sendable {
    public var inProgress: [JiraIssue]
    public var ready: [JiraIssue]
    public var backlog: [JiraIssue]

    /// Every ticket listed.
    public var count: Int { inProgress.count + ready.count + backlog.count }

    public init(
        issues: [JiraIssue], readyStatuses: [String], finishedStatuses: [String] = [], keysWithRuns: Set<String> = []
    ) {
        let readyNames = Set(readyStatuses.map { $0.lowercased() })
        let finishedNames = Set(finishedStatuses.map { $0.lowercased() })
        let open = issues.filter { !keysWithRuns.contains($0.key) }
        inProgress = open.filter { $0.statusCategory == .inProgress && !finishedNames.contains($0.statusName.lowercased()) }
        let todo = open.filter { $0.statusCategory == .toDo }
        ready = todo.filter { readyNames.contains($0.statusName.lowercased()) }
        backlog = todo.filter { !readyNames.contains($0.statusName.lowercased()) }
    }

    /// The small line under a ticket to do: "KEY · iOS · Backlog", with the platforms of the repos whose
    /// rules match it (title prefix, label or component, see `RepoMatcher`), left out when none does.
    public static func context(of issue: JiraIssue, repos: [RepoConfig]) -> String {
        let platforms = RepoMatcher.repos(for: issue, in: repos).map { RepoName.display($0.name) }
        let parts = [issue.key] + (platforms.isEmpty ? [] : [platforms.joined(separator: ", ")]) + [issue.statusName]
        return parts.joined(separator: " · ")
    }

    /// The keys of the tickets that have a run, finished or not: its card stands for the ticket (until the
    /// run is released).
    public static func keysWithRuns(_ runs: [Run]) -> Set<String> {
        Set(runs.map(\.key))
    }

    /// The panel sections: "In progress" when some are, then "Ready to start" and "Backlog" when both have
    /// tickets, else one "To do".
    public var sections: [TodoSection] {
        let ongoing = inProgress.isEmpty ? [] : [TodoSection(title: "In progress", issues: inProgress)]
        if !ready.isEmpty, !backlog.isEmpty {
            return ongoing + [TodoSection(title: "Ready to start", issues: ready), TodoSection(title: "Backlog", issues: backlog)]
        }
        let all = ready + backlog
        return ongoing + (all.isEmpty ? [] : [TodoSection(title: "To do", issues: all)])
    }
}

public struct TodoSection: Equatable, Sendable {
    public var title: String
    public var issues: [JiraIssue]
}
