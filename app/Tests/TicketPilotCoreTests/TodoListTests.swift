import Testing
@testable import TicketPilotCore

private func issue(_ key: String, status: String, category: JiraIssue.StatusCategory) -> JiraIssue {
    JiraIssue(key: key, summary: "Summary \(key)", statusName: status, statusCategory: category)
}

@Suite struct TodoListTests {
    @Test func test_todoListKeepsToDoCategoryOnly() {
        let list = TodoList(
            issues: [
                issue("ABC-1", status: "To Start", category: .toDo),
                issue("ABC-2", status: "In Progress", category: .inProgress),
            ],
            readyStatuses: ["To Start"]
        )

        #expect((list.ready + list.backlog).map(\.key) == ["ABC-1"])
    }

    @Test func test_readyStatusesGoFirst() {
        let list = TodoList(
            issues: [
                issue("ABC-1", status: "Backlog", category: .toDo),
                issue("ABC-2", status: "to start", category: .toDo),
                issue("ABC-3", status: "Backlog", category: .toDo),
                issue("ABC-4", status: "To Start", category: .toDo),
            ],
            readyStatuses: ["To Start"]
        )

        #expect(list.ready.map(\.key) == ["ABC-2", "ABC-4"])
        #expect(list.backlog.map(\.key) == ["ABC-1", "ABC-3"])
        #expect(list.count == list.ready.count + list.backlog.count)
        #expect(list.count == 4)
    }
}
