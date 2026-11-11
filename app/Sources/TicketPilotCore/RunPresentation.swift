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
        case .needsYou: "Waiting for you"
        case .inProgress: "TicketPilot is working on"
        case .reportReady: "Ready for you"
        }
    }
}

/// A run's card in the panel: the ticket's title, a small line "KEY · Repo · <state>", a sentence in plain
/// words, and how far it went.
public struct RunLine: Equatable, Sendable {
    /// The plugin's steps (`ticket_pilot/runs.py`), one progress dot each.
    public static let stepCount = 10

    public var runID: String
    public var section: RunSection
    /// The key, with the repo when the ticket has runs in several repos: what VoiceOver names the card by.
    public var name: String
    /// The ticket's title (`RunTitle.of`).
    public var title: String
    /// "KEY · iOS · <Jira status>": the ticket's status in Jira, never the run's own state (which is in
    /// `detail`); without the status while unknown, without the key when it is already the title.
    public var context: String
    /// "Waiting for your answer: <question>", "Verifying · 12 min", "3 commits ready for review".
    /// "Maybe stuck" is `isStuck`.
    public var detail: String
    public var isStuck: Bool
    /// The progress dots to fill, up to the current step; nil for a finished run.
    public var filledSteps: Int?
    /// The current step in plain words ("Verifying").
    public var stepTitle: String
    /// What the session button says (`SessionButton.title`).
    public var sessionButton: String

    /// The progress dots read aloud: "Step 6 of 10, Verifying"; nil without dots.
    public var progressDescription: String? {
        filledSteps.map { "Step \($0) of \(Self.stepCount), \(stepTitle)" }
    }

    /// `showsRepo` names the repo after the key, for a ticket with runs in several repos. `summary` is the
    /// ticket's summary in Jira, used when the run has no title of its own. `commits`: how many the finished
    /// run made (`CommitCounter`), nil while unknown. `jiraStatus`: the ticket's status name in Jira.
    public static func make(
        _ run: Run, now: Date, stuckMinutes: [String: Int], showsRepo: Bool = false, summary: String? = nil,
        commits: Int? = nil, jiraStatus: String? = nil
    ) -> RunLine {
        let stepStart = run.history.last?.startedAt ?? run.updatedAt
        let stepMinutes = minutes(from: stepStart, to: now)
        let threshold = stuckMinutes[run.stepName] ?? StuckThresholds.defaults[run.stepName]
        let isStuck = run.status == .running && threshold.map { stepMinutes > $0 } == true
        let section = RunSection.of(run)
        let detail: String
        switch section {
        case .needsYou:
            detail = waitingSentence(run.waiting)
        case .inProgress:
            detail = "Step \(run.step) of \(stepCount) · " + stepLabel(run.stepName) + " · " + duration(stepMinutes)
        case .reportReady:
            detail = switch commits {
            case nil: "Ready for review"
            case 1?: "1 commit ready for review"
            case let count?: "\(count) commits ready for review"
            }
        }
        let repo = RepoName.display(run.repo)
        let title = RunTitle.of(run, summaries: summary.map { [run.key: $0] } ?? [:])
        // A run with no title shows its key as the title: it is not repeated below.
        let status = jiraStatus.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let context = ((title == run.key ? [] : [run.key]) + [repo] + (status.map { [$0] } ?? []))
            .joined(separator: " · ")
        return RunLine(
            runID: run.id,
            section: section,
            name: showsRepo ? "\(run.key) · \(repo)" : run.key,
            title: title,
            context: context,
            detail: detail,
            isStuck: isStuck,
            filledSteps: section == .reportReady ? nil : min(max(run.step, 0), stepCount),
            stepTitle: stepLabel(run.stepName),
            sessionButton: SessionButton.title(for: run)
        )
    }

    /// A question reads "Waiting for your answer: <question>"; any other text as written; no text as the
    /// kind's fallback, as a sentence.
    private static func waitingSentence(_ waiting: Run.Waiting?) -> String {
        guard let waiting, !waiting.text.isEmpty else {
            return NotificationText.fallback(waiting?.kind ?? "") + "."
        }
        return waiting.kind == "question" ? "Waiting for your answer: \(waiting.text)" : waiting.text
    }

    /// The plugin's steps, in order (`STEP_NAMES` in `ticket_pilot/runs.py`).
    public static let stepNames = [
        "understand", "prepare", "research", "compare", "implement", "verify", "app_test", "review", "commits",
        "report",
    ]

    /// What the plugin's step is doing, in plain words; an unknown step reads as its name, capitalized.
    public static func stepLabel(_ stepName: String) -> String {
        switch stepName {
        case "understand": "Understanding the ticket"
        case "prepare": "Preparing the workspace"
        case "research": "Researching the other platforms"
        case "compare": "Comparing and deciding"
        case "implement": "Coding"
        case "verify": "Verifying (build, tests)"
        case "app_test": "Testing in the app"
        case "review": "Reviewing the code"
        case "commits": "Creating the commits"
        case "report": "Writing the report"
        default: stepName.prefix(1).uppercased() + stepName.dropFirst()
        }
    }

    /// The phrase of step `number` (1 to 10), each progress dot's tooltip.
    public static func stepPhrase(_ number: Int) -> String {
        stepNames.indices.contains(number - 1) ? stepLabel(stepNames[number - 1]) : "Step \(number)"
    }

    /// "Show in Finder · <size>", the size left out while unknown; nil without a worktree.
    public static func showInFinderTitle(_ run: Run, bytes: Int64?) -> String? {
        guard run.worktree != nil else { return nil }
        guard let bytes = sizeLabel(bytes: bytes) else { return "Show in Finder" }
        return "Show in Finder · " + bytes
    }

    /// The worktree's size, the label of the panel's folder button; nil while unknown.
    public static func sizeLabel(bytes: Int64?) -> String? {
        bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    private static func minutes(from start: Date, to end: Date) -> Int {
        max(0, Int(end.timeIntervalSince(start) / 60))
    }

    /// "45 min", "2 h 14", past a day "1 d 3 h".
    private static func duration(_ minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) min" }
        guard minutes >= 24 * 60 else { return "\(minutes / 60) h " + String(format: "%02d", minutes % 60) }
        return "\(minutes / (24 * 60)) d \(minutes % (24 * 60) / 60) h"
    }
}

/// The runs of one panel section, the most recently updated first.
public struct RunGroup: Equatable, Sendable {
    public var section: RunSection
    public var lines: [RunLine]

    /// The non-empty sections, in the panel order.
    /// `summaries`: the Jira summary of each ticket, by key, for the runs without a title of their own;
    /// `commits`: the commits of each finished run, by run id; `jiraStatuses`: each ticket's Jira status, by key.
    public static func make(
        runs: [Run], now: Date, stuckMinutes: [String: Int], summaries: [String: String] = [:],
        commits: [String: Int] = [:], jiraStatuses: [String: String] = [:]
    ) -> [RunGroup] {
        let runsPerKey = Dictionary(grouping: runs, by: \.key).mapValues(\.count)
        let ordered = runs.sorted { ($0.updatedAt, $1.id) > ($1.updatedAt, $0.id) }
        return RunSection.allCases.compactMap { section in
            let lines = ordered.filter { RunSection.of($0) == section }.map {
                RunLine.make(
                    $0, now: now, stuckMinutes: stuckMinutes,
                    showsRepo: runsPerKey[$0.key, default: 0] > 1, summary: summaries[$0.key],
                    commits: commits[$0.id], jiraStatus: jiraStatuses[$0.key]
                )
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

/// The title a run is shown with.
public enum RunTitle {
    /// The run's own title, else the ticket's summary in Jira, else its key.
    public static func of(_ run: Run, summaries: [String: String]) -> String {
        for candidate in [run.title, summaries[run.key]] {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        }
        return run.key
    }
}

/// How a repo is named in the panel.
public enum RepoName {
    /// The platform names spelled as they are ("ios" reads "iOS"); any other name as is.
    public static func display(_ name: String) -> String {
        switch name.lowercased() {
        case "ios": "iOS"
        case "android": "Android"
        case "web": "Web"
        default: name
        }
    }
}

/// What the button that opens a run's session says. It always does what `SessionAction.forOpening` says.
public enum SessionButton {
    /// A finished run always reads "Read the report", even with its session closed (it is then resumed):
    /// that is what the user wants. Otherwise "Resume" for a closed session (or none), else "Answer" or
    /// "Follow".
    public static func title(for run: Run) -> String {
        let section = RunSection.of(run)
        if section == .reportReady { return "Read the report" }
        switch SessionAction.forOpening(run) {
        case .resume, .start: return "Resume"
        case .bringToFront: return section == .needsYou ? "Answer" : "Follow"
        }
    }

    /// The notification's button: the run waits for an answer, or its report is ready.
    public static func title(for event: NeedsYouEvent) -> String {
        switch event {
        case .waiting: "Answer"
        case .reportReady: "Read the report"
        }
    }
}
