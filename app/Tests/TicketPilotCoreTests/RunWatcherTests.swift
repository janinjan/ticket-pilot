import Foundation
import Testing
@testable import TicketPilotCore

@Suite(.timeLimit(.minutes(1))) struct RunWatcherTests {
    @Test func test_watcherFiresOnNewFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await confirmation(expectedCount: 1...) { fired in
            let watcher = RunWatcher(directory: directory) { fired() }
            watcher.start()
            defer { watcher.stop() }
            try "{}".write(to: directory.appendingPathComponent("a.json"), atomically: true, encoding: .utf8)
            try await Task.sleep(for: .seconds(1))
        }
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }
}
