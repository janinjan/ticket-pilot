import Foundation
import Testing
@testable import TicketPilotCore

private func issue(_ key: String, status: String, category: JiraIssue.StatusCategory) -> JiraIssue {
    JiraIssue(key: key, summary: "Summary \(key)", statusName: status, statusCategory: category)
}

@Suite(.timeLimit(.minutes(1))) struct TodoListTests {
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

    @Test func test_contextNamesThePlatformsOfTheMatchingRepos() throws {
        func repo(_ name: String, _ match: MatchRules) throws -> RepoConfig {
            let json = #"{"name": "\#(name)", "path": "/tmp/\#(name)", "main_branch": "main", "review": "none"}"#
            var repo = try JSONDecoder().decode(RepoConfig.self, from: Data(json.utf8))
            repo.match = match
            return repo
        }
        let repos = [
            try repo("ios", MatchRules(titlePrefixes: ["[iOS]"], components: ["iOS"])),
            try repo("android", MatchRules(titlePrefixes: ["[AND]"])),
        ]
        func ticket(_ summary: String, components: [String] = []) -> JiraIssue {
            JiraIssue(
                key: "ABC-1", summary: summary, statusName: "Backlog", statusCategory: .toDo,
                labels: [], components: components
            )
        }
        #expect(TodoList.context(of: ticket("Show the seller", components: ["iOS"]), repos: repos) == "ABC-1 · iOS · Backlog")
        #expect(TodoList.context(of: ticket("[iOS][AND] Show the seller"), repos: repos) == "ABC-1 · iOS, Android · Backlog")
        #expect(TodoList.context(of: ticket("Show the seller"), repos: repos) == "ABC-1 · Backlog")
    }

    @Test func test_aTicketWithARunInProgressIsNotListed() {
        let list = TodoList(
            issues: [
                issue("ABC-1", status: "To Start", category: .toDo),
                issue("ABC-2", status: "Backlog", category: .toDo),
                issue("ABC-3", status: "Backlog", category: .toDo),
            ],
            readyStatuses: ["To Start"],
            keysWithRuns: ["ABC-1", "ABC-3"]
        )
        #expect((list.ready + list.backlog).map(\.key) == ["ABC-2"])
    }

    @Test func test_anyRunHidesATicket() {
        func run(_ key: String, _ status: Run.Status) -> Run {
            Run(
                id: "\(key)--ios", key: key, repo: "ios", repoPath: "/r", worktree: nil, branch: nil, sessionID: nil,
                session: nil, step: 1, stepName: "understand", status: status, waiting: nil, history: [],
                updatedAt: .distantPast
            )
        }
        let runs = [run("ABC-1", .running), run("ABC-2", .waiting), run("ABC-3", .done), run("ABC-4", .unknown)]
        #expect(TodoList.keysWithRuns(runs) == ["ABC-1", "ABC-2", "ABC-3", "ABC-4"])
    }
}
