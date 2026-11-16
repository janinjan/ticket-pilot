import Foundation
import Testing
@testable import TicketPilotCore

@Suite(.timeLimit(.minutes(1))) struct TicketsFreshnessTests {
    private let now = Date(timeIntervalSinceReferenceDate: 100_000)

    private func text(secondsAgo: TimeInterval?, refreshing: Bool = false) -> String? {
        TicketsFreshness.text(
            lastUpdate: secondsAgo.map { now.addingTimeInterval(-$0) }, refreshing: refreshing, now: now
        )
    }

    @Test func test_saysNothingBeforeTheFirstUpdate() {
        #expect(text(secondsAgo: nil) == nil)
    }

    @Test func test_saysItIsUpdatingWhileRefreshing() {
        #expect(text(secondsAgo: nil, refreshing: true) == "Updating tickets…")
        #expect(text(secondsAgo: 600, refreshing: true) == "Updating tickets…")
    }

    @Test func test_tellsHowLongAgoTheTicketsWereUpdated() {
        #expect(text(secondsAgo: 0) == "Tickets updated just now")
        #expect(text(secondsAgo: -5) == "Tickets updated just now")
        #expect(text(secondsAgo: 59) == "Tickets updated just now")
        #expect(text(secondsAgo: 60) == "Tickets updated 1 min ago")
        #expect(text(secondsAgo: 59 * 60 + 59) == "Tickets updated 59 min ago")
        #expect(text(secondsAgo: 60 * 60) == "Tickets updated 1 h ago")
        #expect(text(secondsAgo: 3 * 60 * 60 + 10) == "Tickets updated 3 h ago")
    }
}
