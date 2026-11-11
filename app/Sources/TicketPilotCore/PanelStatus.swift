import Foundation

/// The status at the top of the panel, shown only when the user must act: a headline and the line under it.
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

    /// Only what the user must act on, else nil (the cards then start right under the header). In order:
    /// the Atlassian sign-in in progress (the panel's button then cancels it), the setup problem
    /// ("Almost there! 👋" and its explanation, the button next to them), tickets waiting for the user
    /// (one line: their cards are listed below).
    public static func make(runs: [Run], setupProblem: SetupProblem?, signingIn: Bool = false) -> PanelStatus? {
        if signingIn {
            return PanelStatus(
                headline: "Waiting for Atlassian sign-in…", subtitle: "Finish signing in in your browser.", needsSetup: true
            )
        }
        if let setupProblem {
            return PanelStatus(headline: "Almost there! 👋", subtitle: setupProblem.explanation, needsSetup: true)
        }
        let waiting = runs.filter { RunSection.of($0) == .needsYou }
        guard !waiting.isEmpty else { return nil }
        let tickets = Set(waiting.map(\.key)).count
        let headline = tickets == 1 ? "1 ticket needs you" : "\(tickets) tickets need you"
        return PanelStatus(headline: headline, subtitle: nil, needsSetup: false)
    }

    /// What the list says when it is empty: nothing before Jira first answered (`todoCount` nil).
    public static func emptyListText(hasRuns: Bool, todoCount: Int?) -> String? {
        !hasRuns && todoCount == 0 ? "No tickets assigned to you" : nil
    }
}
