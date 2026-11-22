import Foundation
import Testing
@testable import TicketPilotCore

@Suite(.timeLimit(.minutes(1))) struct StartingTicketsTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)

    func run(key: String) -> Run {
        Run(
            id: "\(key)--ios", key: key, repo: "ios", repoPath: "/r", worktree: nil, branch: nil,
            sessionID: nil, session: nil, step: 1, stepName: "understand", status: .running,
            waiting: nil, history: [], updatedAt: Self.t0
        )
    }

    @Test func test_aStartedTicketIsStartingUntilItsRunAppears() {
        var starting = StartingTickets()
        starting.mark("ABC-1", at: Self.t0)
        starting.settle(runs: [], now: Self.t0.addingTimeInterval(30))
        #expect(starting.contains("ABC-1"))
        starting.settle(runs: [run(key: "ABC-1")], now: Self.t0.addingTimeInterval(40))
        #expect(!starting.contains("ABC-1"))
    }

    @Test func test_aStartThatNeverShowsUpStopsWaitingAfterThreeMinutes() {
        var starting = StartingTickets()
        starting.mark("ABC-1", at: Self.t0)
        starting.settle(runs: [], now: Self.t0.addingTimeInterval(179))
        #expect(starting.contains("ABC-1"))
        starting.settle(runs: [], now: Self.t0.addingTimeInterval(180))
        #expect(!starting.contains("ABC-1"))
    }

    @Test func test_aFailedStartIsCleared() {
        var starting = StartingTickets()
        starting.mark("ABC-1", at: Self.t0)
        starting.mark("ABC-2", at: Self.t0)
        starting.clear("ABC-1")
        #expect(!starting.contains("ABC-1"))
        #expect(starting.contains("ABC-2"))
    }
}
