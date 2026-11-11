/// Open tickets still to do, those in a "ready" status first. A ticket with a run not done yet is left
/// out: its run card already stands for it.
public struct TodoList: Equatable, Sendable {
    public var ready: [JiraIssue]
    public var backlog: [JiraIssue]

    public init(issues: [JiraIssue], readyStatuses: [String], keysWithRuns: Set<String> = []) {
        let readyNames = Set(readyStatuses.map { $0.lowercased() })
        let todo = issues.filter { $0.statusCategory == .toDo && !keysWithRuns.contains($0.key) }
        ready = todo.filter { readyNames.contains($0.statusName.lowercased()) }
        backlog = todo.filter { !readyNames.contains($0.statusName.lowercased()) }
    }

    /// The keys of the tickets that have a run not done yet.
    public static func keysWithRuns(_ runs: [Run]) -> Set<String> {
        Set(runs.filter { $0.status != .done }.map(\.key))
    }

    /// The panel sections: "Ready to start" and "Backlog" when both have tickets, else one "To do".
    public var sections: [TodoSection] {
        if !ready.isEmpty, !backlog.isEmpty {
            return [TodoSection(title: "Ready to start", issues: ready), TodoSection(title: "Backlog", issues: backlog)]
        }
        let all = ready + backlog
        return all.isEmpty ? [] : [TodoSection(title: "To do", issues: all)]
    }
}

public struct TodoSection: Equatable, Sendable {
    public var title: String
    public var issues: [JiraIssue]
}
