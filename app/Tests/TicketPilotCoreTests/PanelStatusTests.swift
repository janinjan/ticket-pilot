import Foundation
import Testing
@testable import TicketPilotCore

@Suite struct PanelStatusTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let connectJira = SetupProblem(title: "Connect Jira…", headline: "Jira isn't connected yet", action: .setJiraToken)

    static func run(
        _ id: String, _ status: Run.Status, key: String = "ABC-1", repo: String = "ios", updatedMinutesAgo: Int = 0
    ) -> Run {
        Run(
            id: id, key: key, repo: repo, repoPath: "/r", worktree: nil, branch: nil, sessionID: nil,
            session: nil, step: 3, stepName: "research", status: status,
            waiting: status == .waiting ? Run.Waiting(kind: "question", text: "?", since: now) : nil,
            history: [], updatedAt: now.addingTimeInterval(-Double(updatedMinutesAgo) * 60)
        )
    }

    static func make(
        _ runs: [Run], acknowledged: Set<String> = [], problem: SetupProblem? = nil, todoCount: Int? = 0
    ) -> PanelStatus {
        PanelStatus.make(runs: runs, acknowledgedDone: acknowledged, setupProblem: problem, todoCount: todoCount)
    }

    @Test func test_quietSaysHowManyTicketsAreLeftToDo() {
        #expect(Self.make([]) == PanelStatus(headline: "All quiet", subtitle: "No ticket assigned", tint: .calm))
        #expect(Self.make([], todoCount: 1).subtitle == "1 ticket to do")
        #expect(Self.make([], todoCount: 3).subtitle == "3 tickets to do")
        // Before the first Jira answer, nothing is claimed about the tickets.
        #expect(Self.make([], todoCount: nil).subtitle == nil)
    }

    @Test func test_waitingRunsComeFirstAndNameTheLatestOne() {
        let runs = [
            Self.run("a", .waiting, key: "ABC-1", updatedMinutesAgo: 30),
            Self.run("b", .waiting, key: "ABC-2", repo: "web", updatedMinutesAgo: 2),
            Self.run("c", .done),
            Self.run("d", .running),
        ]
        let status = Self.make(runs, problem: Self.connectJira)
        #expect(status == PanelStatus(headline: "2 need you", subtitle: "ABC-2 · web", tint: .attention))
        #expect(Self.make([Self.run("a", .waiting)]).headline == "1 needs you")
    }

    @Test func test_aSetupProblemComesNextAsACalmSentence() {
        // The button says what to do ("Connect Jira…"); the headline only says what is missing.
        let status = Self.make([Self.run("c", .done), Self.run("d", .running)], problem: Self.connectJira)
        #expect(status == PanelStatus(headline: "Jira isn't connected yet", subtitle: nil, tint: .attention))
    }

    @Test func test_reportsNotOpenedYetComeBeforeRunsInProgress() {
        let runs = [
            Self.run("c", .done, key: "ABC-3", updatedMinutesAgo: 10),
            Self.run("e", .done, key: "ABC-4", updatedMinutesAgo: 1),
            Self.run("d", .running, key: "ABC-5"),
        ]
        #expect(Self.make(runs) == PanelStatus(headline: "2 reports ready", subtitle: "ABC-4 · ios", tint: .calm))
        #expect(Self.make(runs, acknowledged: ["e"]).headline == "1 report ready")
        #expect(Self.make(runs, acknowledged: ["e"]).subtitle == "ABC-3 · ios")
    }

    @Test func test_runsInProgressIncludeAnUnknownStatus() {
        let runs = [Self.run("d", .running, key: "ABC-5", updatedMinutesAgo: 5), Self.run("u", .unknown, key: "ABC-6")]
        #expect(Self.make(runs) == PanelStatus(headline: "2 in progress", subtitle: "ABC-6 · ios", tint: .calm))
        // Every report opened and nothing at work: quiet again.
        #expect(Self.make([Self.run("c", .done)], acknowledged: ["c"]).headline == "All quiet")
    }
}
