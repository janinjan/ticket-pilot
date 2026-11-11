import Foundation
import Testing
@testable import TicketPilotCore

@Suite(.timeLimit(.minutes(1))) struct SessionActionTests {
    private static func run(sessionID: String?, state: String?) -> Run {
        Run(
            id: "ABC-1--ios", key: "ABC-1", repo: "ios", repoPath: "/r", worktree: nil, branch: nil,
            sessionID: sessionID,
            session: state.map { Run.SessionInfo(state: $0, lastNotification: nil, notifiedAt: nil, endedAt: nil) },
            step: 1, stepName: "Read", status: .running, waiting: nil, history: [],
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test func endedSessionResumes() {
        #expect(SessionAction.forOpening(Self.run(sessionID: "s1", state: "ended")) == .resume)
    }

    @Test func sessionWithoutInfoResumes() {
        #expect(SessionAction.forOpening(Self.run(sessionID: "s1", state: nil)) == .resume)
    }

    @Test func runningOrWaitingSessionComesToFront() {
        #expect(SessionAction.forOpening(Self.run(sessionID: "s1", state: "running")) == .bringToFront)
        #expect(SessionAction.forOpening(Self.run(sessionID: "s1", state: "waiting")) == .bringToFront)
    }

    @Test func unknownSessionStateResumes() {
        #expect(SessionAction.forOpening(Self.run(sessionID: "s1", state: "weird")) == .resume)
    }

    @Test func runWithoutSessionStarts() {
        #expect(SessionAction.forOpening(Self.run(sessionID: nil, state: nil)) == .start)
        #expect(SessionAction.forOpening(Self.run(sessionID: nil, state: "ended")) == .start)
    }

    @Test func endedAtDecodesAndIsOptional() throws {
        func decode(_ session: String) throws -> Run {
            let json = """
            {"id":"a","key":"ABC-1","repo":"r","repo_path":"/r","step":1,"step_name":"s","status":"running",
             "updated_at":"2026-01-01T00:00:00Z",\(session)}
            """
            return try JSONDecoder.runDecoder.decode(Run.self, from: Data(json.utf8))
        }
        let ended = try decode(#""session":{"state":"ended","ended_at":"2026-01-01T01:00:00Z"}"#)
        #expect(ended.session?.endedAt == ISO8601DateFormatter().date(from: "2026-01-01T01:00:00Z"))
        let running = try decode(#""session":{"state":"running"}"#)
        #expect(running.session?.endedAt == nil)
        let bad = try decode(#""session":{"state":"ended","ended_at":"garbage"}"#)
        #expect(bad.session?.state == "ended")
        #expect(bad.session?.endedAt == nil)
    }
}
