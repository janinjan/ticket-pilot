/// Open tickets still to do, those in a "ready" status first.
public struct TodoList: Equatable, Sendable {
    public var ready: [JiraIssue]
    public var backlog: [JiraIssue]

    public init(issues: [JiraIssue], readyStatuses: [String]) {
        let readyNames = Set(readyStatuses.map { $0.lowercased() })
        let todo = issues.filter { $0.statusCategory == .toDo }
        ready = todo.filter { readyNames.contains($0.statusName.lowercased()) }
        backlog = todo.filter { !readyNames.contains($0.statusName.lowercased()) }
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
