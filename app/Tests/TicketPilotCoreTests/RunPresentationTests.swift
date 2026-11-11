import Foundation
import Testing
@testable import TicketPilotCore

@Suite(.timeLimit(.minutes(1))) struct RunPresentationTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func run(
        id: String = "ABC-1--ios",
        status: Run.Status = .running,
        stepName: String = "verify",
        step: Int = 6,
        startedMinutesAgo: Int? = 12,
        waitingMinutesAgo: Int? = nil
    ) -> Run {
        let history = startedMinutesAgo.map {
            [Run.HistoryEntry(step: step, startedAt: now.addingTimeInterval(-Double($0) * 60), endedAt: nil)]
        } ?? []
        let waiting = waitingMinutesAgo.map {
            Run.Waiting(kind: "question", text: "?", since: now.addingTimeInterval(-Double($0) * 60))
        }
        return Run(
            id: id, key: "ABC-1", repo: "ios", repoPath: "/r", worktree: nil, branch: nil, sessionID: nil,
            session: nil, step: step, stepName: stepName, status: status, waiting: waiting,
            history: history, updatedAt: now
        )
    }

    @Test func test_iconPriority() {
        let waiting = Self.run(id: "w", status: .waiting, waitingMinutesAgo: 1)
        let done = Self.run(id: "d", status: .done)
        let running = Self.run(id: "r")
        #expect(RunIconState.make(runs: [waiting, done], acknowledgedDone: []) == .waiting(count: 1))
        #expect(RunIconState.make(runs: [done], acknowledgedDone: []) == .reportReady)
        #expect(RunIconState.make(runs: [done], acknowledgedDone: ["d"]) == .idle)
        #expect(RunIconState.make(runs: [running, done], acknowledgedDone: []) == .reportReady)
        #expect(RunIconState.make(runs: [running], acknowledgedDone: []) == .running)
        #expect(RunIconState.make(runs: [], acknowledgedDone: []) == .idle)
    }

    @Test func test_runSectionFollowsTheStatus() {
        #expect(RunSection.of(Self.run(status: .waiting, waitingMinutesAgo: 1)) == .needsYou)
        #expect(RunSection.of(Self.run(status: .running)) == .inProgress)
        #expect(RunSection.of(Self.run(status: .unknown)) == .inProgress)
        #expect(RunSection.of(Self.run(status: .done)) == .reportReady)
        // Never readable as a Jira status.
        #expect(RunSection.allCases.map(\.title) == ["Waiting for you", "TicketPilot is working on", "Ready for you"])
    }

    @Test func test_stepLabelsSayWhatTheStepDoes() {
        let labels = [
            "understand": "Understanding the ticket", "prepare": "Preparing the workspace",
            "research": "Researching the other platforms", "compare": "Comparing and deciding",
            "implement": "Coding", "verify": "Verifying (build, tests)", "app_test": "Testing in the app",
            "review": "Reviewing the code", "commits": "Creating the commits", "report": "Writing the report",
        ]
        for (name, label) in labels {
            #expect(RunLine.stepLabel(name) == label)
        }
        #expect(RunLine.stepLabel("mystery") == "Mystery")
        #expect(RunLine.stepLabel("") == "")
        // Each dot's tooltip, by step number, in the plugin's order.
        #expect((1...10).map(RunLine.stepPhrase) == [
            "Understanding the ticket", "Preparing the workspace", "Researching the other platforms",
            "Comparing and deciding", "Coding", "Verifying (build, tests)", "Testing in the app",
            "Reviewing the code", "Creating the commits", "Writing the report",
        ])
        #expect(RunLine.stepPhrase(11) == "Step 11")
    }

    @Test func test_inProgressLineShowsTheStepAndItsDuration() {
        let line = RunLine.make(Self.run(), now: Self.now, stuckMinutes: [:], summary: "Show the distance")
        #expect(line.runID == "ABC-1--ios")
        #expect(line.section == .inProgress)
        #expect(line.name == "ABC-1")
        #expect(line.title == "Show the distance")
        // The small line gives the ticket's Jira status, never the run's own state.
        #expect(line.context == "ABC-1 · iOS")
        let withStatus = RunLine.make(Self.run(), now: Self.now, stuckMinutes: [:], summary: "Show the distance", jiraStatus: "In Review")
        #expect(withStatus.context == "ABC-1 · iOS · In Review")
        #expect(line.detail == "Step 6 of 10 · Verifying (build, tests) · 12 min")

        let long = RunLine.make(Self.run(startedMinutesAgo: 65), now: Self.now, stuckMinutes: ["verify": 90])
        #expect(long.detail == "Step 6 of 10 · Verifying (build, tests) · 1 h 05")
        #expect(long.title == "ABC-1")

        let days = RunLine.make(Self.run(startedMinutesAgo: 27 * 60 + 10), now: Self.now, stuckMinutes: ["verify": 9999])
        #expect(days.detail == "Step 6 of 10 · Verifying (build, tests) · 1 d 3 h")

        let fallback = RunLine.make(Self.run(startedMinutesAgo: nil), now: Self.now, stuckMinutes: [:])
        #expect(fallback.detail == "Step 6 of 10 · Verifying (build, tests) · 0 min")

        let stuck = RunLine.make(Self.run(stepName: "implement", step: 5, startedMinutesAgo: 121), now: Self.now, stuckMinutes: [:])
        // "Maybe stuck" is a tag of its own, not part of the text.
        #expect(stuck.detail == "Step 5 of 10 · Coding · 2 h 01")
        #expect(stuck.isStuck)
    }

    @Test func test_needsYouLineSaysWhatTheRunWaitsFor() {
        var run = Self.run(status: .waiting, waitingMinutesAgo: 5)
        run.waiting?.text = "Which layout?"
        let line = RunLine.make(run, now: Self.now, stuckMinutes: [:])
        #expect(line.detail == "Waiting for your answer: Which layout?")
        // Without a title of its own, the key is the title and is not repeated below it.
        #expect(line.title == "ABC-1")
        #expect(line.context == "iOS")
        #expect(RunLine.make(run, now: Self.now, stuckMinutes: [:], jiraStatus: "To Start").context == "iOS · To Start")
        #expect(line.section == .needsYou)
        run.waiting = Run.Waiting(kind: "go", text: "Summary, and the JIRA line?", since: Self.now)
        #expect(RunLine.make(run, now: Self.now, stuckMinutes: [:]).detail == "Summary, and the JIRA line?")
        let fallbacks = [
            "go": "Waiting for your go.", "launch_app": "Launch the app.",
            "input": "Waiting for your input.", "question": "Waiting for you.",
        ]
        for (kind, text) in fallbacks {
            run.waiting = Run.Waiting(kind: kind, text: "", since: Self.now)
            #expect(RunLine.make(run, now: Self.now, stuckMinutes: [:]).detail == text)
        }
        run.waiting = nil
        #expect(RunLine.make(run, now: Self.now, stuckMinutes: [:]).detail == "Waiting for you.")
    }

    @Test func test_reportReadyLineSaysSoWithoutATime() {
        var run = Self.run(status: .done, startedMinutesAgo: nil)
        run.updatedAt = Self.now.addingTimeInterval(-36 * 60)
        let line = RunLine.make(run, now: Self.now, stuckMinutes: [:])
        #expect(line.section == .reportReady)
        #expect(line.detail == "Ready for review")
        #expect(RunLine.make(run, now: Self.now, stuckMinutes: [:], commits: 1).detail == "1 commit ready for review")
        #expect(RunLine.make(run, now: Self.now, stuckMinutes: [:], commits: 4).detail == "4 commits ready for review")
        // A finished run gives no time: it no longer matters.
        #expect(line.context == "iOS")
        let titled = RunLine.make(run, now: Self.now, stuckMinutes: [:], summary: "Show the distance", jiraStatus: "Backlog")
        #expect(titled.context == "ABC-1 · iOS · Backlog")
    }

    @Test func test_theSessionButtonSaysWhatTheRunNeeds() {
        let live = Run.SessionInfo(state: "running", lastNotification: nil, notifiedAt: nil)
        func button(_ status: Run.Status, session: Run.SessionInfo?, sessionID: String? = "s1") -> String {
            var run = Self.run(status: status, waitingMinutesAgo: status == .waiting ? 1 : nil)
            run.sessionID = sessionID
            run.session = session
            return RunLine.make(run, now: Self.now, stuckMinutes: [:]).sessionButton
        }
        #expect(button(.waiting, session: live) == "Answer")
        #expect(button(.running, session: live) == "Follow")
        #expect(button(.unknown, session: live) == "Follow")
        #expect(button(.done, session: live) == "Read the report")
        // A closed session, or none at all, reads "Resume" while the run is not done.
        let ended = Run.SessionInfo(state: "ended", lastNotification: nil, notifiedAt: nil)
        #expect(button(.waiting, session: ended) == "Resume")
        #expect(button(.running, session: nil, sessionID: nil) == "Resume")
        // A finished run's session is resumed too, but reading the report is what the user wants.
        #expect(button(.done, session: ended) == "Read the report")
        #expect(button(.done, session: nil, sessionID: nil) == "Read the report")
    }

    @Test func test_notificationsOfferTheSameButton() {
        #expect(SessionButton.title(for: .waiting(runID: "r", key: "ABC-1", kind: "go", text: "")) == "Answer")
        #expect(SessionButton.title(for: .reportReady(runID: "r", key: "ABC-1")) == "Read the report")
    }

    @Test func test_stuckUsesDefaultsAndOverrides() {
        let implement = Self.run(stepName: "implement", step: 5, startedMinutesAgo: 121)
        #expect(RunLine.make(implement, now: Self.now, stuckMinutes: [:]).isStuck)
        #expect(!RunLine.make(implement, now: Self.now, stuckMinutes: ["implement": 200]).isStuck)
        let waiting = Self.run(status: .waiting, stepName: "implement", step: 5, startedMinutesAgo: 500, waitingMinutesAgo: 500)
        #expect(!RunLine.make(waiting, now: Self.now, stuckMinutes: [:]).isStuck)
        let unknownStep = Self.run(stepName: "mystery", startedMinutesAgo: 9999)
        #expect(!RunLine.make(unknownStep, now: Self.now, stuckMinutes: [:]).isStuck)
    }

    @Test func test_groupsFollowTheSectionOrderAndPutTheLatestUpdateFirst() {
        func run(_ id: String, _ status: Run.Status, updatedMinutesAgo: Int) -> Run {
            var run = Self.run(id: id, status: status, waitingMinutesAgo: status == .waiting ? 1 : nil)
            run.key = id
            run.updatedAt = Self.now.addingTimeInterval(-Double(updatedMinutesAgo) * 60)
            return run
        }
        let runs = [
            run("D-1", .done, updatedMinutesAgo: 50),
            run("R-1", .running, updatedMinutesAgo: 30),
            run("D-2", .done, updatedMinutesAgo: 5),
            run("R-2", .unknown, updatedMinutesAgo: 10),
        ]
        let groups = RunGroup.make(runs: runs, now: Self.now, stuckMinutes: [:])
        #expect(groups.map(\.section) == [.inProgress, .reportReady])
        #expect(groups.map { $0.lines.map(\.runID) } == [["R-2", "R-1"], ["D-2", "D-1"]])
        #expect(RunGroup.make(runs: [], now: Self.now, stuckMinutes: [:]).isEmpty)
    }

    @Test func test_theRepoIsNamedOnlyWhenATicketHasSeveralRuns() {
        var ios = Self.run(id: "ABC-1--ios")
        var android = Self.run(id: "ABC-1--android")
        android.repo = "android"
        ios.updatedAt = Self.now
        android.updatedAt = Self.now.addingTimeInterval(-60)
        let lines = RunGroup.make(
            runs: [ios, android], now: Self.now, stuckMinutes: [:], summaries: ["ABC-1": "Map"], jiraStatuses: ["ABC-1": "To Start"]
        )[0].lines
        #expect(lines.map(\.context) == ["ABC-1 · iOS · To Start", "ABC-1 · Android · To Start"])
        #expect(lines.map(\.name) == ["ABC-1 · iOS", "ABC-1 · Android"])
        #expect(lines.map(\.title) == ["Map", "Map"])
    }

    @Test func test_progressFillsTheDotsUpToTheCurrentStepOfRunsNotDone() {
        #expect(RunLine.stepCount == 10)
        #expect(RunLine.make(Self.run(step: 6), now: Self.now, stuckMinutes: [:]).filledSteps == 6)
        #expect(RunLine.make(Self.run(step: 1), now: Self.now, stuckMinutes: [:]).filledSteps == 1)
        let waiting = Self.run(status: .waiting, step: 3, waitingMinutesAgo: 1)
        #expect(RunLine.make(waiting, now: Self.now, stuckMinutes: [:]).filledSteps == 3)
        #expect(RunLine.make(Self.run(status: .unknown, step: 4), now: Self.now, stuckMinutes: [:]).filledSteps == 4)
        #expect(RunLine.make(Self.run(status: .done, step: 10), now: Self.now, stuckMinutes: [:]).filledSteps == nil)
        // A step out of range from another plugin version stays within the dots.
        #expect(RunLine.make(Self.run(step: 14), now: Self.now, stuckMinutes: [:]).filledSteps == 10)
        #expect(RunLine.make(Self.run(step: -2), now: Self.now, stuckMinutes: [:]).filledSteps == 0)
    }

    @Test func test_progressReadsAsTheStepOutOfTenWithItsName() {
        #expect(RunLine.make(Self.run(step: 6), now: Self.now, stuckMinutes: [:]).progressDescription == "Step 6 of 10, Verifying (build, tests)")
        #expect(RunLine.make(Self.run(status: .done), now: Self.now, stuckMinutes: [:]).progressDescription == nil)
    }

    @Test func test_showInFinderNamesTheSizeWhenKnown() {
        var run = Self.run()
        #expect(RunLine.showInFinderTitle(run, bytes: 5_000_000) == nil)
        run.worktree = "/Users/me/wt/ios"
        let size = ByteCountFormatter.string(fromByteCount: 5_000_000, countStyle: .file)
        #expect(RunLine.showInFinderTitle(run, bytes: 5_000_000) == "Show in Finder · \(size)")
        #expect(RunLine.showInFinderTitle(run, bytes: nil) == "Show in Finder")
        #expect(RunLine.sizeLabel(bytes: 5_000_000) == size)
        #expect(RunLine.sizeLabel(bytes: nil) == nil)
    }

    @Test func test_menuBarIconShowsWhatNeedsYouAndSetupProblems() {
        #expect(MenuBarIcon.make(iconState: .idle, hasSetupProblem: false) == MenuBarIcon(badge: nil, showsProblem: false))
        #expect(MenuBarIcon.make(iconState: .running, hasSetupProblem: false).badge == nil)
        #expect(MenuBarIcon.make(iconState: .waiting(count: 2), hasSetupProblem: false).badge == "2")
        #expect(MenuBarIcon.make(iconState: .reportReady, hasSetupProblem: false).badge == "✓")
        #expect(MenuBarIcon.make(iconState: .reportReady, hasSetupProblem: true) == MenuBarIcon(badge: "✓", showsProblem: true))
        #expect(MenuBarIcon.make(iconState: .idle, hasSetupProblem: true) == MenuBarIcon(badge: nil, showsProblem: true))
    }

    @Test func test_menuBarIconTellsVoiceOverWhatItsBadgeMeans() {
        #expect(MenuBarIcon(badge: nil, showsProblem: false).accessibilityValue == "")
        #expect(MenuBarIcon(badge: "1", showsProblem: false).accessibilityValue == "1 needs you")
        #expect(MenuBarIcon(badge: "3", showsProblem: false).accessibilityValue == "3 need you")
        #expect(MenuBarIcon(badge: "✓", showsProblem: false).accessibilityValue == "Report ready")
        #expect(MenuBarIcon(badge: "2", showsProblem: true).accessibilityValue == "2 need you, setup needed")
        #expect(MenuBarIcon(badge: nil, showsProblem: true).accessibilityValue == "Setup needed")
    }

    @Test func test_keepsMacAwakeOnlyForRunningRunsThatAreNotStuck() {
        let fresh = Self.run(id: "r", stepName: "verify", startedMinutesAgo: 12)
        let interrupted = Self.run(id: "s", stepName: "verify", startedMinutesAgo: 61)
        let waiting = Self.run(id: "w", status: .waiting, waitingMinutesAgo: 1)
        let done = Self.run(id: "d", status: .done)
        #expect(SleepPolicy.keepsMacAwake(runs: [fresh], now: Self.now, stuckMinutes: [:]))
        #expect(!SleepPolicy.keepsMacAwake(runs: [interrupted], now: Self.now, stuckMinutes: [:]))
        #expect(SleepPolicy.keepsMacAwake(runs: [interrupted, fresh], now: Self.now, stuckMinutes: [:]))
        #expect(!SleepPolicy.keepsMacAwake(runs: [waiting, done], now: Self.now, stuckMinutes: [:]))
        #expect(!SleepPolicy.keepsMacAwake(runs: [], now: Self.now, stuckMinutes: [:]))
        // The configured threshold wins over the default one.
        #expect(!SleepPolicy.keepsMacAwake(runs: [fresh], now: Self.now, stuckMinutes: ["verify": 10]))
    }
}
