import Foundation

/// What the session button of a run ("Answer", "Follow", "Read the report", "Resume") does.
public enum SessionAction: Equatable, Sendable {
    /// The session ended (or its state is unknown): reopen it in a new terminal window.
    case resume
    /// The session is live in some terminal tab: bring the terminal to the front.
    case bringToFront
    /// The run never had a session: start one.
    case start

    /// What to do with Ghostty, which is scriptable: its tab list is authoritative.
    public enum GhosttyOutcome: Equatable, Sendable {
        case focus(terminalID: String)
        case openNewTab
        case bringGhosttyToFront
    }

    /// `terminals` is the tab list, nil when it could not be read. A tab that matches the run is focused;
    /// when none does the session is closed, whatever its recorded state, and is resumed in a new tab.
    /// Only an unreadable list protects a live session from being started a second time.
    public func ghosttyOutcome(terminals: [TerminalSurface]?, key: String, folders: [String]) -> GhosttyOutcome {
        guard let terminals else {
            return self == .bringToFront ? .bringGhosttyToFront : .openNewTab
        }
        let live = self == .bringToFront
        if let id = SessionLocator.pickTerminal(terminals, key: key, folders: folders, claudeOnly: !live) {
            return .focus(terminalID: id)
        }
        return .openNewTab
    }

    public static func forOpening(_ run: Run) -> SessionAction {
        guard run.sessionID != nil else { return .start }
        guard let session = run.session else { return .resume }
        switch session.state {
        case "running", "waiting": return .bringToFront
        default: return .resume
        }
    }
}
