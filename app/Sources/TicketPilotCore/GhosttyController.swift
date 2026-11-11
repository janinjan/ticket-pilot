import Foundation

public enum GhosttyError: Error, Equatable, Sendable {
    /// Automation permission for Ghostty was refused (error -1743).
    case permissionDenied
    /// The script did not finish: most likely the Automation prompt was left unanswered.
    case timedOut
    case scriptFailed(String)

    /// Identifies the kind of error, whatever its message.
    public var kind: String {
        switch self {
        case .permissionDenied: "permissionDenied"
        case .timedOut: "timedOut"
        case .scriptFailed: "scriptFailed"
        }
    }

    public var alertText: AlertText {
        switch self {
        case .permissionDenied:
            AlertText(
                title: "TicketPilot cannot control Ghostty",
                message: "Allow TicketPilot to control Ghostty in System Settings › Privacy & Security › Automation. "
                    + "Until then, the session button brings Ghostty to the front without choosing a tab."
            )
        case .timedOut:
            AlertText(
                title: "Ghostty did not answer",
                message: "macOS may be waiting for your answer to the Automation prompt. Allow TicketPilot to "
                    + "control Ghostty in System Settings › Privacy & Security › Automation. "
                    + "Until then, the session button brings Ghostty to the front without choosing a tab."
            )
        case let .scriptFailed(message):
            AlertText(
                title: "Ghostty did not answer",
                message: "\(message)\n\nThe session button brings Ghostty to the front without choosing a tab."
            )
        }
    }
}

/// Drives Ghostty (1.3 or later) through its AppleScript dictionary with `/usr/bin/osascript`.
/// It only lists and focuses terminals, and opens a new tab; it never types into an existing one.
public struct GhosttyController: Sendable {
    public var runner: ProcessRunning

    private static let osascript = "/usr/bin/osascript"
    private static let fieldSeparator = "\u{1F}"
    private static let recordSeparator = "\u{1E}"

    public init(runner: ProcessRunning) {
        self.runner = runner
    }

    public func listTerminals() throws -> [TerminalSurface] {
        return Self.parse(try execute(Self.listScript))
    }

    public func focus(terminalID: String) throws {
        _ = try execute("""
        tell application "Ghostty"
            focus (first terminal whose id is \(Self.literal(terminalID)))
            activate
        end tell
        """)
    }

    /// The title of the selected tab of Ghostty's front window, nil without a window. Only call it while
    /// Ghostty runs: a `tell` would launch it.
    public func selectedTabTitle() throws -> String? {
        let title = try execute("""
        tell application "Ghostty"
            if (count of windows) is 0 then return ""
            return name of selected tab of front window
        end tell
        """).trimmingCharacters(in: .newlines)
        return title.isEmpty ? nil : title
    }

    /// Brings Ghostty to the front, without choosing a tab.
    public func activate() throws {
        _ = try execute("""
        tell application "Ghostty" to activate
        """)
    }

    /// Opens a new tab (a new window when none is open) in `directory` and types `command` in it.
    public func openTab(directory: String, command: String) throws {
        _ = try execute("""
        tell application "Ghostty"
            activate
            set cfg to new surface configuration from {initial working directory:\(Self.literal(directory)), \
        initial input:\(Self.literal(command)) & linefeed}
            if (count of windows) is 0 then
                new window with configuration cfg
            else
                new tab in front window with configuration cfg
            end if
        end tell
        """)
    }

    /// The AppleScript sources, exposed so tests can check that none can type into or close a terminal.
    static let listScript = """
        tell application "Ghostty"
            set output to ""
            repeat with t in every terminal
                set output to output & (id of t) & (ASCII character 31) & (name of t) \
        & (ASCII character 31) & (working directory of t) & (ASCII character 30) & linefeed
            end repeat
            return output
        end tell
        """

    static func parse(_ output: String) -> [TerminalSurface] {
        output.components(separatedBy: recordSeparator).compactMap { record in
            let fields = record.trimmingCharacters(in: .newlines).components(separatedBy: fieldSeparator)
            guard fields.count == 3, !fields[0].isEmpty else { return nil }
            return TerminalSurface(id: fields[0], name: fields[1], workingDirectory: fields[2])
        }
    }

    /// An AppleScript string literal: backslashes and quotes escaped.
    static func literal(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    private func execute(_ script: String) throws -> String {
        let result: ProcessResult
        do {
            result = try runner.run(Self.osascript, ["-e", script], currentDirectory: nil)
        } catch {
            throw GhosttyError.scriptFailed("\(error)")
        }
        guard result.status == 0 else {
            if result.error.contains("-1743") { throw GhosttyError.permissionDenied }
            if result.error.contains("timed out after") { throw GhosttyError.timedOut }
            throw GhosttyError.scriptFailed(result.error.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.output
    }
}
