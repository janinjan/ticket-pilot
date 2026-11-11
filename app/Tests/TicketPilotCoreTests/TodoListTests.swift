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
    }

    @Test func test_sectionsAreOneToDoListUnlessBothKindsExist() {
        let ready = issue("ABC-1", status: "To Start", category: .toDo)
        let backlog = issue("ABC-2", status: "Backlog", category: .toDo)
        func titles(_ issues: [JiraIssue]) -> [String] {
            TodoList(issues: issues, readyStatuses: ["To Start"]).sections.map(\.title)
        }
        #expect(titles([ready, backlog]) == ["Ready to start", "Backlog"])
        #expect(titles([ready]) == ["To do"])
        #expect(titles([backlog]) == ["To do"])
        #expect(titles([]) == [])
        let both = TodoList(issues: [backlog, ready], readyStatuses: ["To Start"]).sections
        #expect(both.map { $0.issues.map(\.key) } == [["ABC-1"], ["ABC-2"]])
    }
}
