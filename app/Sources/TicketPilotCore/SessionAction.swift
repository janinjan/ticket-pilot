import Foundation

/// What "Open session" does for a run.
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

extension SessionAction {
    /// "Session open in: <folder>": the run's worktree, else its repo, with the home folder shown as `~`.
    public static func openInLine(_ run: Run, home: String = NSHomeDirectory()) -> String {
        let folder = run.worktree ?? run.repoPath
        let shown = folder == home ? "~" : folder.hasPrefix(home + "/") ? "~" + folder.dropFirst(home.count) : folder
        return "Session open in: \(shown)"
    }
}
