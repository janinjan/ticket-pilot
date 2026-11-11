import Foundation

/// The status line at the top of the panel: a headline and the line under it.
public struct PanelStatus: Equatable, Sendable {
    public var headline: String
    public var subtitle: String?
    /// The setup must be fixed: the panel shows the status as a banner holding the fix button.
    public var needsSetup: Bool

    public init(headline: String, subtitle: String?, needsSetup: Bool) {
        self.headline = headline
        self.subtitle = subtitle
        self.needsSetup = needsSetup
    }

    /// In order: the Atlassian sign-in in progress (the panel's button then cancels it), the setup problem ("Almost there! 👋" and its explanation, the button next to them),
    /// tickets waiting for the user, reports not opened yet, runs in progress, else "All quiet" with the
    /// number of tickets to do (`todoCount` is nil until Jira first answered). The subtitle names the most
    /// recently updated run of the headline by its title (`RunTitle.of`, with `summaries` from Jira).
    public static func make(
        runs: [Run],
        acknowledgedDone: Set<String>,
        setupProblem: SetupProblem?,
        todoCount: Int?,
        summaries: [String: String] = [:],
        signingIn: Bool = false
    ) -> PanelStatus {
        if signingIn {
            return PanelStatus(
                headline: "Waiting for Atlassian sign-in…", subtitle: "Finish signing in in your browser.", needsSetup: true
            )
        }
        if let setupProblem {
            return PanelStatus(headline: "Almost there! 👋", subtitle: setupProblem.explanation, needsSetup: true)
        }
        func title(_ run: Run?) -> String? {
            run.map { RunTitle.of($0, summaries: summaries) }
        }
        let waiting = runs.filter { RunSection.of($0) == .needsYou }
        if !waiting.isEmpty {
            let tickets = Set(waiting.map(\.key)).count
            let headline = tickets == 1 ? "1 ticket needs you" : "\(tickets) tickets need you"
            return PanelStatus(headline: headline, subtitle: title(latest(waiting)), needsSetup: false)
        }
        let reports = runs.filter { RunSection.of($0) == .reportReady && !acknowledgedDone.contains($0.id) }
        if !reports.isEmpty {
            let headline = reports.count == 1 ? "Your report is ready 🎉" : "\(reports.count) reports are ready 🎉"
            return PanelStatus(headline: headline, subtitle: title(latest(reports)), needsSetup: false)
        }
        let working = runs.filter { RunSection.of($0) == .inProgress }
        if let run = latest(working) {
            let subtitle = RunLine.stepLabel(run.stepName) + " · " + RunTitle.of(run, summaries: summaries)
            return PanelStatus(headline: "Working on it…", subtitle: subtitle, needsSetup: false)
        }
        let subtitle: String? = switch todoCount {
        case nil: nil
        case 0: "No ticket assigned"
        case 1: "1 ticket to do"
        case let count?: "\(count) tickets to do"
        }
        return PanelStatus(headline: "All quiet. Enjoy your coffee ☕", subtitle: subtitle, needsSetup: false)
    }

    private static func latest(_ runs: [Run]) -> Run? {
        runs.max { ($0.updatedAt, $1.id) < ($1.updatedAt, $0.id) }
    }
}
