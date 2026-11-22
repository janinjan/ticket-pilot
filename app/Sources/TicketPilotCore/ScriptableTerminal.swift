import Foundation

/// An error of a scriptable terminal, reported once per `kind`.
public protocol ScriptableTerminalError: Error, Sendable {
    /// Identifies the kind of error, whatever its message.
    var kind: String { get }
    var alertText: AlertText { get }
    /// What identifies an alert already shown: the kind by default.
    var alertKey: String { get }
}

public extension ScriptableTerminalError {
    var alertKey: String { kind }
}

/// A terminal app TicketPilot drives itself (Ghostty through AppleScript, Orca through its CLI): it lists
/// and focuses tabs, and opens new ones; it never types into an existing tab.
public protocol ScriptableTerminal: Sendable {
    func listTerminals() throws -> [TerminalSurface]
    func focus(terminalID: String) throws
    /// Brings the app to the front, without choosing a tab.
    func activate() throws
    /// Opens a new tab in `directory`, running `command`; `title` names the tab when the terminal can.
    func openTab(directory: String, command: String, title: String) throws
}
