import Foundation
import Testing
@testable import TicketPilotCore

private func issue(_ key: String) -> JiraIssue {
    JiraIssue(key: key, summary: "Summary \(key)", statusName: "To Start", statusCategory: .toDo)
}

@Suite(.timeLimit(.minutes(1))) struct TicketTrackerTests {
    @Test func test_firstSuccessRecordsSilently() {
        let outcome = TicketTracker.apply(.success([issue("ABC-1"), issue("ABC-2")]), seen: nil)

        #expect(outcome.toNotify == [])
        #expect(outcome.seen == ["ABC-1", "ABC-2"])
        #expect(outcome.failed == false)
    }

    @Test func test_notifiesOnlyNeverSeenKeys() {
        let outcome = TicketTracker.apply(.success([issue("ABC-1"), issue("ABC-2")]), seen: ["ABC-1"])

        #expect(outcome.toNotify.map(\.key) == ["ABC-2"])
        #expect(outcome.seen == ["ABC-1", "ABC-2"])
    }

    @Test func test_keepsKeysThatLeftTheResult() {
        let outcome = TicketTracker.apply(.success([]), seen: ["ABC-1"])

        #expect(outcome.toNotify == [])
        #expect(outcome.seen == ["ABC-1"])
    }

    @Test func test_failedPollKeepsSeenUntouched() {
        let first = TicketTracker.apply(.failure(.unreachable), seen: nil)
        #expect(first.toNotify == [])
        #expect(first.seen == nil)
        #expect(first.failed == true)

        let later = TicketTracker.apply(.failure(.unreachable), seen: ["ABC-1"])
        #expect(later.toNotify == [])
        #expect(later.seen == nil)
        #expect(later.failed == true)
    }

    @Test func test_seenStoreRoundTripAndCorruptFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("app/seen.json")
        let store = SeenStore(file: file)

        #expect(store.load() == nil)

        try store.save(["ABC-2", "ABC-1"])
        #expect(store.load() == ["ABC-1", "ABC-2"])
        #expect(try String(contentsOf: file, encoding: .utf8).contains("\"ABC-1\""))

        try Data("{not json".utf8).write(to: file)
        #expect(store.load() == nil)
    }
}
