import Foundation

public enum RunIconState: Equatable, Sendable {
    case idle, running, waiting(count: Int), reportReady

    /// Priority: waiting > reportReady > running > idle.
    public static func make(runs: [Run], acknowledgedDone: Set<String>) -> RunIconState {
        let waitingCount = runs.filter { $0.status == .waiting }.count
        if waitingCount > 0 { return .waiting(count: waitingCount) }
        if runs.contains(where: { $0.status == .done && !acknowledgedDone.contains($0.id) }) {
            return .reportReady
        }
        if runs.contains(where: { $0.status == .running }) { return .running }
        return .idle
    }
}

public enum StuckThresholds {
    public static let defaults: [String: Int] = [
        "understand": 30, "prepare": 15, "research": 30, "compare": 30, "implement": 120,
        "verify": 60, "app_test": 90, "review": 45, "commits": 60, "report": 20,
    ]
}

public struct RunLine: Equatable, Sendable {
    public var runID: String
    public var title: String
    public var detail: String
    public var waitingFor: String?
    public var isStuck: Bool

    static let totalSteps = 10

    public static func make(_ run: Run, now: Date, stuckMinutes: [String: Int]) -> RunLine {
        let stepStart = run.history.last?.startedAt ?? run.updatedAt
        let stepMinutes = minutes(from: stepStart, to: now)
        var waitingFor: String?
        if run.status == .waiting {
            waitingFor = "waiting \(duration(minutes(from: run.waiting?.since ?? run.updatedAt, to: now)))"
        }
        let threshold = stuckMinutes[run.stepName] ?? StuckThresholds.defaults[run.stepName]
        let isStuck = run.status == .running && threshold.map { stepMinutes > $0 } == true
        return RunLine(
            runID: run.id,
            title: "\(run.key) · \(run.repo)",
            detail: "\(run.step)/\(totalSteps) · \(run.stepName) · \(duration(stepMinutes))",
            waitingFor: waitingFor,
            isStuck: isStuck
        )
    }

    private static func minutes(from start: Date, to end: Date) -> Int {
        max(0, Int(end.timeIntervalSince(start) / 60))
    }

    private static func duration(_ minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) min" }
        return "\(minutes / 60) h " + String(format: "%02d", minutes % 60)
    }
}

public enum SleepPolicy {
    /// True while a run is `running` and not stuck: a run interrupted without its status being
    /// updated (Esc, Ctrl-C, crash) stops keeping the Mac awake once it passes its step threshold.
    public static func keepsMacAwake(runs: [Run], now: Date, stuckMinutes: [String: Int]) -> Bool {
        runs.contains { $0.status == .running && !RunLine.make($0, now: now, stuckMinutes: stuckMinutes).isStuck }
    }
}

/// The registry line of a run's submenu: "worktree · branch · size", or nil without a worktree.
public enum RegistryLine {
    public static func make(_ run: Run, bytes: Int64?) -> String? {
        guard let worktree = run.worktree else { return nil }
        let size = bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return [worktree, run.branch, size].compactMap { $0 }.joined(separator: " · ")
    }
}

/// What the menu bar icon shows next to the ticket symbol.
public struct MenuBarIcon: Equatable, Sendable {
    /// The number of tickets to do, or `?` while Jira cannot be read.
    public var countText: String
    /// SF Symbol name of the run state, if any.
    public var stateSymbol: String?
    /// Number shown after the state symbol (runs waiting for the user).
    public var stateCount: Int?
    /// Alert dot: a setup check failed.
    public var showsAlert: Bool

    public static func make(
        todoCount: Int, iconState: RunIconState, jiraFailing: Bool, hasHealthProblem: Bool
    ) -> MenuBarIcon {
        var symbol: String?
        var count: Int?
        switch iconState {
        case .idle: break
        case .running: symbol = "ellipsis"
        case let .waiting(waiting):
            symbol = "hand.raised"
            count = waiting
        case .reportReady: symbol = "checkmark"
        }
        return MenuBarIcon(
            countText: jiraFailing ? "?" : String(todoCount),
            stateSymbol: symbol,
            stateCount: count,
            showsAlert: hasHealthProblem
        )
    }
}
