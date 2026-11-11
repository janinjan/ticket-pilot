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

/// The panel section a run is listed in.
public enum RunSection: CaseIterable, Equatable, Sendable {
    case needsYou, inProgress, reportReady

    public static func of(_ run: Run) -> RunSection {
        switch run.status {
        case .waiting: .needsYou
        case .running, .unknown: .inProgress
        case .done: .reportReady
        }
    }

    public var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .inProgress: "In progress"
        case .reportReady: "Report ready"
        }
    }
}

/// A run's card in the panel: its name, what is happening, and how far it went.
public struct RunLine: Equatable, Sendable {
    /// The plugin's steps (`ticket_pilot/runs.py`), one progress dot each.
    public static let stepCount = 10

    public var runID: String
    public var section: RunSection
    /// The key, with the repo when the ticket has runs in several repos.
    public var name: String
    /// The question, the step and its duration, or "Done · <time>". "Maybe stuck" is `isStuck`.
    public var detail: String
    public var isStuck: Bool
    /// The progress dots to fill, up to the current step; nil for a finished run.
    public var filledSteps: Int?
    /// The current step in plain words ("Verifying").
    public var stepTitle: String

    /// The progress dots read aloud: "Step 6 of 10, Verifying"; nil without dots.
    public var progressDescription: String? {
        filledSteps.map { "Step \($0) of \(Self.stepCount), \(stepTitle)" }
    }

    /// `showsRepo` names the repo after the key, for a ticket with runs in several repos.
    public static func make(_ run: Run, now: Date, stuckMinutes: [String: Int], showsRepo: Bool = false) -> RunLine {
        let stepStart = run.history.last?.startedAt ?? run.updatedAt
        let stepMinutes = minutes(from: stepStart, to: now)
        let threshold = stuckMinutes[run.stepName] ?? StuckThresholds.defaults[run.stepName]
        let isStuck = run.status == .running && threshold.map { stepMinutes > $0 } == true
        let section = RunSection.of(run)
        let detail = switch section {
        case .needsYou:
            run.waiting.map { $0.text.isEmpty ? NotificationText.fallback($0.kind) : $0.text }
                ?? NotificationText.fallback("")
        case .inProgress:
            stepLabel(run.stepName) + " · " + duration(stepMinutes)
        case .reportReady:
            "Done · " + duration(minutes(from: run.updatedAt, to: now))
        }
        return RunLine(
            runID: run.id,
            section: section,
            name: showsRepo ? "\(run.key) · \(run.repo)" : run.key,
            detail: detail,
            isStuck: isStuck,
            filledSteps: section == .reportReady ? nil : min(max(run.step, 0), stepCount),
            stepTitle: stepLabel(run.stepName)
        )
    }

    /// What the plugin's step is doing, in plain words; an unknown step reads as its name, capitalized.
    public static func stepLabel(_ stepName: String) -> String {
        switch stepName {
        case "understand": "Understanding"
        case "prepare": "Preparing"
        case "research": "Researching"
        case "compare": "Comparing"
        case "implement": "Coding"
        case "verify": "Verifying"
        case "app_test": "Testing in the app"
        case "review": "Reviewing"
        case "commits": "Committing"
        case "report": "Writing the report"
        default: stepName.prefix(1).uppercased() + stepName.dropFirst()
        }
    }

    /// "Show in Finder · <size>", the size left out while unknown; nil without a worktree.
    public static func showInFinderTitle(_ run: Run, bytes: Int64?) -> String? {
        guard run.worktree != nil else { return nil }
        guard let bytes else { return "Show in Finder" }
        return "Show in Finder · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func minutes(from start: Date, to end: Date) -> Int {
        max(0, Int(end.timeIntervalSince(start) / 60))
    }

    private static func duration(_ minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) min" }
        return "\(minutes / 60) h " + String(format: "%02d", minutes % 60)
    }
}

/// The runs of one panel section, the most recently updated first.
public struct RunGroup: Equatable, Sendable {
    public var section: RunSection
    public var lines: [RunLine]

    /// The non-empty sections, in the panel order.
    public static func make(runs: [Run], now: Date, stuckMinutes: [String: Int]) -> [RunGroup] {
        let runsPerKey = Dictionary(grouping: runs, by: \.key).mapValues(\.count)
        let ordered = runs.sorted { ($0.updatedAt, $1.id) > ($1.updatedAt, $0.id) }
        return RunSection.allCases.compactMap { section in
            let lines = ordered.filter { RunSection.of($0) == section }.map {
                RunLine.make($0, now: now, stuckMinutes: stuckMinutes, showsRepo: runsPerKey[$0.key, default: 0] > 1)
            }
            return lines.isEmpty ? nil : RunGroup(section: section, lines: lines)
        }
    }
}

public enum SleepPolicy {
    /// True while a run is `running` and not stuck: a run interrupted without its status being
    /// updated (Esc, Ctrl-C, crash) stops keeping the Mac awake once it passes its step threshold.
    public static func keepsMacAwake(runs: [Run], now: Date, stuckMinutes: [String: Int]) -> Bool {
        runs.contains { $0.status == .running && !RunLine.make($0, now: now, stuckMinutes: stuckMinutes).isStuck }
    }
}

/// What the menu bar shows next to the app's mark.
public struct MenuBarIcon: Equatable, Sendable {
    /// The number of runs waiting for the user, else "✓" for a report not opened yet, else nothing.
    public var badge: String?
    /// A small "!": the panel offers a setup problem to fix.
    public var showsProblem: Bool

    public init(badge: String?, showsProblem: Bool) {
        self.badge = badge
        self.showsProblem = showsProblem
    }

    /// What VoiceOver says after "TicketPilot": the badge in words, and the setup problem.
    public var accessibilityValue: String {
        let badgeText: String? = switch badge {
        case nil: nil
        case "✓": "Report ready"
        case "1": "1 needs you"
        case let count?: "\(count) need you"
        }
        let parts = [badgeText, showsProblem ? "setup needed" : nil].compactMap { $0 }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    public static func make(iconState: RunIconState, hasSetupProblem: Bool) -> MenuBarIcon {
        let badge: String? = switch iconState {
        case .idle, .running: nil
        case let .waiting(count): String(count)
        case .reportReady: "✓"
        }
        return MenuBarIcon(badge: badge, showsProblem: hasSetupProblem)
    }
}
