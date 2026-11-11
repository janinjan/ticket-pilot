import Foundation

/// How the panel's big mark is drawn: always the app icon's navy and orange, never an alarm colour.
public enum PanelTint: Equatable, Sendable {
    /// Nothing needs the user: the mark as in the app icon.
    case calm
    /// A run needs the user, or the setup must be fixed: the bright orange is emphasized.
    case attention
}

/// The headline under the panel's big mark, the run it is about, and the mark's colour.
public struct PanelStatus: Equatable, Sendable {
    public var headline: String
    public var subtitle: String?
    public var tint: PanelTint

    public init(headline: String, subtitle: String?, tint: PanelTint) {
        self.headline = headline
        self.subtitle = subtitle
        self.tint = tint
    }

    /// In order: runs waiting for the user, the setup problem (its calm `headline`, the button keeps the
    /// action), reports not opened yet, runs in progress, else "All quiet" with the number of tickets to do
    /// (`todoCount` is nil until Jira first answered). The subtitle names the most recently updated run of
    /// the headline: "KEY · repo".
    public static func make(
        runs: [Run], acknowledgedDone: Set<String>, setupProblem: SetupProblem?, todoCount: Int?
    ) -> PanelStatus {
        let waiting = runs.filter { RunSection.of($0) == .needsYou }
        if !waiting.isEmpty {
            let verb = waiting.count == 1 ? "needs" : "need"
            return PanelStatus(headline: "\(waiting.count) \(verb) you", subtitle: latest(waiting), tint: .attention)
        }
        if let setupProblem {
            return PanelStatus(headline: setupProblem.headline, subtitle: nil, tint: .attention)
        }
        let reports = runs.filter { RunSection.of($0) == .reportReady && !acknowledgedDone.contains($0.id) }
        if !reports.isEmpty {
            let noun = reports.count == 1 ? "report" : "reports"
            return PanelStatus(headline: "\(reports.count) \(noun) ready", subtitle: latest(reports), tint: .calm)
        }
        let working = runs.filter { RunSection.of($0) == .inProgress }
        if !working.isEmpty {
            return PanelStatus(headline: "\(working.count) in progress", subtitle: latest(working), tint: .calm)
        }
        let subtitle: String? = switch todoCount {
        case nil: nil
        case 0: "No ticket assigned"
        case 1: "1 ticket to do"
        case let count?: "\(count) tickets to do"
        }
        return PanelStatus(headline: "All quiet", subtitle: subtitle, tint: .calm)
    }

    private static func latest(_ runs: [Run]) -> String? {
        runs.max { ($0.updatedAt, $1.id) < ($1.updatedAt, $0.id) }.map { "\($0.key) · \($0.repo)" }
    }
}
