import Foundation

/// What the session button of a run ("Answer", "Follow", "Read the report", "Resume") does.
public enum SessionAction: Equatable, Sendable {
    /// The session ended (or its state is unknown): reopen it in a new terminal window.
    case resume
    /// The session is live in some terminal tab: bring the terminal to the front.
    case bringToFront
    /// The run never had a session: start one.
    case start

    public static func forOpening(_ run: Run) -> SessionAction {
        guard run.sessionID != nil else { return .start }
        guard let session = run.session else { return .resume }
        switch session.state {
        case "running", "waiting": return .bringToFront
        default: return .resume
        }
    }
}
