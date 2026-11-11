import Foundation
import Testing
@testable import TicketPilotCore

@Suite struct RunStoreTests {
    static let pluginRun = """
    {
      "id": "ABC-1--ios", "key": "ABC-1", "repo": "ios", "repo_path": "/repos/ios",
      "worktree": "/repos/ios-wt", "branch": "abc-1", "session_id": "s1",
      "session": {"state": "running", "last_notification": null, "notified_at": null},
      "step": 6, "step_name": "verify", "status": "waiting",
      "waiting": {"kind": "question", "text": "Which one?", "since": "2026-11-11T10:05:00Z"},
      "jira_line": null, "requests": [],
      "history": [
        {"step": 5, "started_at": "2026-11-11T09:00:00Z", "ended_at": "2026-11-11T10:00:00Z"},
        {"step": 6, "started_at": "2026-11-11T10:00:00Z"}
      ],
      "created_at": "2026-11-11T09:00:00Z", "updated_at": "2026-11-11T10:05:00Z"
    }
    """

    static let olderRun = """
    {
      "id": "ABC-2--web", "key": "ABC-2", "repo": "web", "repo_path": "/repos/web",
      "step": 1, "step_name": "understand", "status": "paused",
      "waiting": {"kind": "input", "text": "", "since": "2026-11-11T10:05:00Z"},
      "history": [], "foo": 1, "updated_at": "2026-11-11T10:05:00Z"
    }
    """

    @Test func test_decodesRunWrittenByThePlugin() throws {
        let run = try JSONDecoder.runDecoder.decode(Run.self, from: Data(Self.pluginRun.utf8))
        #expect(run.status == .waiting)
        #expect(run.waiting?.kind == "question")
        #expect(run.history.count == 2)
        #expect(run.history[0].endedAt != nil)
        #expect(run.history[1].endedAt == nil)
        #expect(run.sessionID == "s1")
        #expect(run.session?.state == "running")
        #expect(run.step == 6)
    }

    @Test func test_decodesRunFromOlderPlugin() throws {
        let run = try JSONDecoder.runDecoder.decode(Run.self, from: Data(Self.olderRun.utf8))
        #expect(run.session == nil)
        #expect(run.waiting?.kind == "input")
        #expect(run.history.isEmpty)
        #expect(run.status == .unknown)
        #expect(run.worktree == nil)

        let malformed = """
        {
          "id": "ABC-2--web", "key": "ABC-2", "repo": "web", "repo_path": "/repos/web",
          "step": 2, "step_name": "prepare", "status": "waiting",
          "waiting": {"kind": "input"},
          "history": [
            {"step": 1, "started_at": "yesterday"},
            {"step": 2, "started_at": "2026-11-11T10:00:00Z"}
          ],
          "updated_at": "2026-11-11T10:05:00Z"
        }
        """
        let kept = try JSONDecoder.runDecoder.decode(Run.self, from: Data(malformed.utf8))
        #expect(kept.waiting == nil)
        #expect(kept.history.map(\.step) == [2])
        let notAList = malformed.replacingOccurrences(of: "\"history\": [", with: "\"history\": {\"x\": [")
            .replacingOccurrences(of: "\"}\n  ],", with: "\"}\n  ]},")
        #expect(try JSONDecoder.runDecoder.decode(Run.self, from: Data(notAList.utf8)).history.isEmpty)
    }

    @Test func test_storeSkipsCorruptAndTempFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.pluginRun.write(to: directory.appendingPathComponent("a.json"), atomically: true, encoding: .utf8)
        try "{not json".write(to: directory.appendingPathComponent("b.json"), atomically: true, encoding: .utf8)
        try Self.olderRun.write(to: directory.appendingPathComponent("c.json.tmp"), atomically: true, encoding: .utf8)
        #expect(RunStore(directory: directory).loadAll().map(\.id) == ["ABC-1--ios"])
    }

    @Test func test_storeSortsByUpdatedAtDescendingAndToleratesMissingDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        #expect(RunStore(directory: directory).loadAll().isEmpty)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.olderRun.write(to: directory.appendingPathComponent("a.json"), atomically: true, encoding: .utf8)
        let newer = Self.pluginRun.replacingOccurrences(of: "\"updated_at\": \"2026-11-11T10:05:00Z\"", with: "\"updated_at\": \"2026-11-11T11:00:00Z\"")
        try newer.write(to: directory.appendingPathComponent("b.json"), atomically: true, encoding: .utf8)
        #expect(RunStore(directory: directory).loadAll().map(\.id) == ["ABC-1--ios", "ABC-2--web"])
    }
}
