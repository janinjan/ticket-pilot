/// Open tickets still to do, those in a "ready" status first.
public struct TodoList: Equatable, Sendable {
    public var ready: [JiraIssue]
    public var backlog: [JiraIssue]

    public var count: Int { ready.count + backlog.count }

    public init(issues: [JiraIssue], readyStatuses: [String]) {
        let readyNames = Set(readyStatuses.map { $0.lowercased() })
        let todo = issues.filter { $0.statusCategory == .toDo }
        ready = todo.filter { readyNames.contains($0.statusName.lowercased()) }
        backlog = todo.filter { !readyNames.contains($0.statusName.lowercased()) }
    }
}
