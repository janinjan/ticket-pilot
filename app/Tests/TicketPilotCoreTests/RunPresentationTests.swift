import Foundation
import Testing
@testable import TicketPilotCore

@Suite struct RunPresentationTests {
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

    @Test func test_runLineFormatsStepAndDurations() {
        let line = RunLine.make(Self.run(), now: Self.now, stuckMinutes: [:])
        #expect(line.title == "ABC-1 · ios")
        #expect(line.detail == "6/10 · verify · 12 min")
        #expect(line.waitingFor == nil)
        #expect(line.runID == "ABC-1--ios")

        let waiting = RunLine.make(
            Self.run(status: .waiting, waitingMinutesAgo: 5), now: Self.now, stuckMinutes: [:]
        )
        #expect(waiting.waitingFor == "waiting 5 min")

        let long = RunLine.make(Self.run(startedMinutesAgo: 65), now: Self.now, stuckMinutes: [:])
        #expect(long.detail == "6/10 · verify · 1 h 05")

        let fallback = RunLine.make(Self.run(startedMinutesAgo: nil), now: Self.now, stuckMinutes: [:])
        #expect(fallback.detail == "6/10 · verify · 0 min")
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

    @Test func test_menuBarIconShowsCountStateAndAlert() {
        let idle = MenuBarIcon.make(todoCount: 3, iconState: .idle, jiraFailing: false, hasHealthProblem: false)
        #expect(idle == MenuBarIcon(countText: "3", stateSymbol: nil, stateCount: nil, showsAlert: false))
        let waiting = MenuBarIcon.make(todoCount: 0, iconState: .waiting(count: 2), jiraFailing: false, hasHealthProblem: true)
        #expect(waiting == MenuBarIcon(countText: "0", stateSymbol: "hand.raised", stateCount: 2, showsAlert: true))
        #expect(MenuBarIcon.make(todoCount: 1, iconState: .running, jiraFailing: false, hasHealthProblem: false).stateSymbol == "ellipsis")
        #expect(MenuBarIcon.make(todoCount: 1, iconState: .reportReady, jiraFailing: false, hasHealthProblem: false).stateSymbol == "checkmark")
        #expect(MenuBarIcon.make(todoCount: 4, iconState: .idle, jiraFailing: true, hasHealthProblem: false).countText == "?")
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

    @Test func test_registryLineShowsWorktreeBranchAndSize() {
        var run = Self.run()
        #expect(RegistryLine.make(run, bytes: 5_000_000) == nil)
        run.worktree = "/repos/ios-wt"
        run.branch = "abc-1"
        let size = ByteCountFormatter.string(fromByteCount: 5_000_000, countStyle: .file)
        #expect(RegistryLine.make(run, bytes: 5_000_000) == "/repos/ios-wt · abc-1 · \(size)")
        #expect(RegistryLine.make(run, bytes: nil) == "/repos/ios-wt · abc-1")
        run.branch = nil
        #expect(RegistryLine.make(run, bytes: 5_000_000) == "/repos/ios-wt · \(size)")
    }
}
