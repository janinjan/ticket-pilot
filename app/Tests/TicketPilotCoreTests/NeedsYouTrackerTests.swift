import Foundation
import Testing
@testable import TicketPilotCore

@Suite(.timeLimit(.minutes(1))) struct NeedsYouTrackerTests {
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

@Suite(.timeLimit(.minutes(1))) struct NotificationStatusTests {
    @Test func test_settingsSaysWhetherNotificationsAndTheirSoundAreAllowed() {
        #expect(NotificationStatus.text(allowed: true, soundAllowed: true) == "Notifications: allowed")
        #expect(NotificationStatus.text(allowed: true, soundAllowed: false) == "Notifications: sound off")
        #expect(NotificationStatus.text(allowed: false, soundAllowed: true) == "Notifications: not allowed")
        #expect(NotificationStatus.text(allowed: false, soundAllowed: false) == "Notifications: not allowed")
    }

    @Test func test_theTestNotificationExplainsItself() {
        #expect(NotificationStatus.testTitle == "TicketPilot test")
        #expect(NotificationStatus.testBody == "This is how TicketPilot tells you a run needs you.")
        #expect(NotificationStatus.settingsURL.absoluteString
            == "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    }
}

@Suite(.timeLimit(.minutes(1))) struct NotificationPolicyTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func run(_ status: Run.Status = .waiting, kind: String = "input", since: Date = t0) -> Run {
        NeedsYouTrackerTests.run(status: status, kind: kind, since: since)
    }

    static func waiting(_ kind: String) -> NeedsYouEvent {
        .waiting(runID: "ABC-1--ios", key: "ABC-1", kind: kind, text: "")
    }

    @Test func test_aRealQuestionNotifiesAtOnceWithSound() {
        for kind in ["go", "question", "launch_app"] {
            #expect(NotificationPolicy.timing(for: Self.waiting(kind), in: [Self.run(kind: kind)], now: Self.t0)
                == .now(sound: true), "\(kind)")
        }
        #expect(NotificationPolicy.timing(for: .reportReady(runID: "ABC-1--ios", key: "ABC-1"), in: [], now: Self.t0)
            == .now(sound: true))
    }

    @Test func test_aPlainEndOfTurnWaitsTwoMinutesAndStaysSilent() {
        let run = Self.run(kind: "input")
        #expect(NotificationPolicy.timing(for: Self.waiting("input"), in: [run], now: Self.t0.addingTimeInterval(5))
            == .after(Self.t0.addingTimeInterval(120), since: Self.t0))
        // Seen only once the two minutes are over (the Mac slept): at once, still silent.
        #expect(NotificationPolicy.timing(for: Self.waiting("input"), in: [run], now: Self.t0.addingTimeInterval(300))
            == .now(sound: false))
    }

    @Test func test_theDelayedNotificationNeedsTheSameWaitStillPending() {
        let since = Self.t0
        #expect(NotificationPolicy.isStillPending(runID: "ABC-1--ios", since: since, in: [Self.run(since: since)]))
        // The user answered (the run went on), or a new turn ended (a new `since`), or the run is gone.
        #expect(!NotificationPolicy.isStillPending(runID: "ABC-1--ios", since: since, in: [Self.run(.running)]))
        #expect(!NotificationPolicy.isStillPending(
            runID: "ABC-1--ios", since: since, in: [Self.run(since: since.addingTimeInterval(30))]
        ))
        #expect(!NotificationPolicy.isStillPending(runID: "ABC-1--ios", since: since, in: []))
    }

    @Test func test_noNotificationWhileTheUserLooksAtTheSessionTab() {
        #expect(NotificationPolicy.userIsWatching(frontmostIsGhostty: true, selectedTabTitle: "✳ ABC-1 Jira ticket", key: "ABC-1"))
        #expect(!NotificationPolicy.userIsWatching(frontmostIsGhostty: false, selectedTabTitle: "✳ ABC-1 Jira ticket", key: "ABC-1"))
        #expect(!NotificationPolicy.userIsWatching(frontmostIsGhostty: true, selectedTabTitle: "✳ ABC-12 other", key: "ABC-1"))
        #expect(!NotificationPolicy.userIsWatching(frontmostIsGhostty: true, selectedTabTitle: nil, key: "ABC-1"))
    }
}
