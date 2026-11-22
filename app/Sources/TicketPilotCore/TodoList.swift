/// Open tickets assigned to the user: in progress (a run released before the ticket is done), then still
/// to do, those in a "ready" status first. A ticket with a run is left out: its run card stands for it.
/// The new tickets (`NewTickets`) are listed apart, under "New" above the runs, and in no other section.
public struct TodoList: Equatable, Sendable {
    public var new: [JiraIssue]
    public var inProgress: [JiraIssue]
    public var ready: [JiraIssue]
    public var backlog: [JiraIssue]
    /// The keys of every ticket listed, new ones included: a new ticket outside it is no longer new.
    public var listedKeys: Set<String>

    /// Every ticket listed.
    public var count: Int { new.count + inProgress.count + ready.count + backlog.count }

    public init(
        issues: [JiraIssue], readyStatuses: [String], finishedStatuses: [String] = [], keysWithRuns: Set<String> = [],
        newKeys: Set<String> = []
    ) {
        let readyNames = Set(readyStatuses.map { $0.lowercased() })
        let finishedNames = Set(finishedStatuses.map { $0.lowercased() })
        let listed = issues.filter { issue in
            guard !keysWithRuns.contains(issue.key) else { return false }
            switch issue.statusCategory {
            case .toDo: return true
            case .inProgress: return !finishedNames.contains(issue.statusName.lowercased())
            case .done: return false
            }
        }
        listedKeys = Set(listed.map(\.key))
        new = listed.filter { newKeys.contains($0.key) }
        let open = listed.filter { !newKeys.contains($0.key) }
        inProgress = open.filter { $0.statusCategory == .inProgress }
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

    /// The "New" section, shown above the runs; nil without a new ticket.
    public var newSection: TodoSection? {
        new.isEmpty ? nil : TodoSection(title: "New", issues: new)
    }

    /// The panel sections under the runs, each shown when it has tickets: "In progress", "Ready to start",
    /// then "Backlog".
    public var sections: [TodoSection] {
        [
            TodoSection(title: "In progress", issues: inProgress),
            TodoSection(title: "Ready to start", issues: ready),
            TodoSection(title: "Backlog", issues: backlog),
        ].filter { !$0.issues.isEmpty }
    }
}

public struct TodoSection: Equatable, Sendable {
    public var title: String
    public var issues: [JiraIssue]
}
