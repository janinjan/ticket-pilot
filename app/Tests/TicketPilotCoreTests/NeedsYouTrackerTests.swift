import Foundation
import Testing
@testable import TicketPilotCore

@Suite struct NeedsYouTrackerTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func run(
        id: String = "ABC-1--ios",
        status: Run.Status = .running,
        kind: String = "go",
        text: String = "Ready?",
        since: Date = t0
    ) -> Run {
        Run(
            id: id, key: "ABC-1", repo: "ios", repoPath: "/r", worktree: nil, branch: nil, sessionID: nil,
            session: nil, step: 3, stepName: "plan", status: status,
            waiting: status == .waiting ? Run.Waiting(kind: kind, text: text, since: since) : nil,
            history: [], updatedAt: t0
        )
    }

    @Test func test_firstCallIsSilent() {
        var tracker = NeedsYouTracker()
        let events = tracker.events(for: [Self.run(status: .waiting), Self.run(id: "d", status: .done)])
        #expect(events.isEmpty)
        #expect(tracker.events(for: [Self.run(status: .waiting), Self.run(id: "d", status: .done)]).isEmpty)
    }

    @Test func test_newWaitingNotifiesOnce() {
        var tracker = NeedsYouTracker()
        _ = tracker.events(for: [Self.run(status: .running)])
        let waiting = Self.run(status: .waiting)
        #expect(tracker.events(for: [waiting]) == [
            .waiting(runID: "ABC-1--ios", key: "ABC-1", kind: "go", text: "Ready?")
        ])
        #expect(tracker.events(for: [waiting]).isEmpty)
    }

    @Test func test_newQuestionOnSameRunNotifiesAgain() {
        var tracker = NeedsYouTracker()
        _ = tracker.events(for: [])
        #expect(tracker.events(for: [Self.run(status: .waiting)]).count == 1)
        let later = Self.run(status: .waiting, text: "Other?", since: Self.t0.addingTimeInterval(60))
        #expect(tracker.events(for: [later]) == [
            .waiting(runID: "ABC-1--ios", key: "ABC-1", kind: "go", text: "Other?")
        ])
    }

    @Test func test_waitingAgainAfterRunningNotifies() {
        var tracker = NeedsYouTracker()
        _ = tracker.events(for: [Self.run(status: .waiting)])
        #expect(tracker.events(for: [Self.run(status: .running)]).isEmpty)
        let again = Self.run(status: .waiting, since: Self.t0.addingTimeInterval(60))
        #expect(tracker.events(for: [again]).count == 1)
    }

    @Test func test_doneNotifiesReportReady() {
        var tracker = NeedsYouTracker()
        _ = tracker.events(for: [Self.run(status: .running)])
        let done = Self.run(status: .done)
        #expect(tracker.events(for: [done]) == [.reportReady(runID: "ABC-1--ios", key: "ABC-1")])
        #expect(tracker.events(for: [done]).isEmpty)
    }

    @Test func test_doneAgainAfterLeavingDoneNotifies() {
        var tracker = NeedsYouTracker()
        _ = tracker.events(for: [Self.run(status: .done)])
        #expect(tracker.events(for: [Self.run(status: .running)]).isEmpty)
        #expect(tracker.events(for: [Self.run(status: .done)]).count == 1)
    }

    @Test func test_runningRunNotifiesNothing() {
        var tracker = NeedsYouTracker()
        _ = tracker.events(for: [Self.run(status: .running)])
        #expect(tracker.events(for: [Self.run(status: .running)]).isEmpty)
    }

    @Test func test_textFallsBackOnKind() {
        func body(_ kind: String, _ text: String) -> String {
            NotificationText.make(.waiting(runID: "r", key: "ABC-1", kind: kind, text: text)).body
        }
        #expect(body("go", "") == "Waiting for your go")
        #expect(body("launch_app", "") == "Launch the app")
        #expect(body("input", "") == "Waiting for your input")
        #expect(body("question", "") == "Waiting for you")
        #expect(body("go", "Proceed?") == "Proceed?")
        #expect(NotificationText.make(.waiting(runID: "r", key: "ABC-1", kind: "go", text: "")).title == "ABC-1 needs you")
        #expect(NotificationText.make(.reportReady(runID: "r", key: "ABC-1")).title == "ABC-1 report ready")
    }

    @Test func test_runThatDisappearsAndReappearsDoesNotNotifyAgain() {
        var tracker = NeedsYouTracker()
        _ = tracker.events(for: [])
        #expect(tracker.events(for: [Self.run(status: .waiting)]).count == 1)
        #expect(tracker.events(for: []).isEmpty)
        #expect(tracker.events(for: [Self.run(status: .waiting)]).isEmpty)
    }

    @Test func test_runFirstSeenAfterStartAlreadyWaitingNotifies() {
        var tracker = NeedsYouTracker()
        _ = tracker.events(for: [])
        #expect(tracker.events(for: [Self.run(status: .waiting)]).count == 1)
    }

    @Test func test_notificationIDFollowsTheWaitOrTheReport() {
        let waiting = Self.run(status: .waiting, since: Self.t0.addingTimeInterval(60))
        let event = NeedsYouEvent.waiting(runID: waiting.id, key: "ABC-1", kind: "go", text: "Ready?")
        #expect(event.runID == "ABC-1--ios")
        #expect(event.notificationID(in: [waiting]) == "ABC-1--ios@1800000060")

        let done = Self.run(status: .done)
        let report = NeedsYouEvent.reportReady(runID: done.id, key: "ABC-1")
        #expect(report.notificationID(in: [done]) == "ABC-1--ios@1800000000")

        let noWaiting = Self.run(status: .running)
        #expect(event.notificationID(in: [noWaiting]) == "ABC-1--ios@1800000000")
        #expect(event.notificationID(in: []) == "ABC-1--ios@unknown")
    }
}
