import Foundation

public enum OrcaError: ScriptableTerminalError, Equatable {
    /// The `orca` CLI was not found in Orca's bundle.
    case notInstalled
    /// Orca did not start, or its runtime never answered.
    case notRunning
    /// The CLI failed: `ok:false`, a non-zero exit or output that is not its JSON.
    case commandFailed(String)

    public var kind: String {
        switch self {
        case .notInstalled: "notInstalled"
        case .notRunning: "notRunning"
        case .commandFailed: "commandFailed"
        }
    }

    /// Orca has no fallback, so a failure with a new message is shown even when its kind was.
    public var alertKey: String {
        if case let .commandFailed(message) = self { return "\(kind).\(message)" }
        return kind
    }

    public var alertText: AlertText {
        let title = "TicketPilot cannot open the session in Orca"
        switch self {
        case .notInstalled:
            return AlertText(title: title, message: "Orca is not installed. Pick another terminal in Settings.")
        case .notRunning:
            return AlertText(title: title, message: "Orca did not start. Open Orca, then try again.")
        case let .commandFailed(message):
            return AlertText(title: title, message: message)
        }
    }
}

/// Drives Orca through its `orca` CLI (`--json` on every command). Sessions open in a terminal tab of the
/// repo's main checkout, which Orca knows as a worktree of the repo; Orca never creates a worktree here.
/// It only lists, focuses and opens tabs; it never types into nor closes an existing one.
public struct OrcaController: ScriptableTerminal {
    public var runner: ProcessRunning
    public var cli: String
    /// Pause between two tries to switch to a tab Orca does not own yet.
    public var retryDelay: TimeInterval

    /// Tries to switch to a tab, the first one included: about five seconds of Orca adopting its tabs.
    public static let focusAttempts = 6

    public init(runner: ProcessRunning, cli: String, retryDelay: TimeInterval = 1) {
        self.runner = runner
        self.cli = cli
        self.retryDelay = retryDelay
    }

    /// "<dir>/Orca.app/Contents/Resources/bin/orca" in the first directory where it exists.
    public static func cliPath(applicationDirectories: [URL] = TerminalDetector.defaultDirectories) -> String? {
        applicationDirectories
            .map { $0.appendingPathComponent("Orca.app/Contents/Resources/bin/orca").path }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Starts Orca first when it is not running: quitting Orca keeps its terminals alive (its daemon hosts
    /// them) and Orca shows them again, so a live session is found rather than started twice.
    public func listTerminals() throws -> [TerminalSurface] {
        try ensureRunning()
        let result = try call(["terminal", "list"])
        guard let terminals = result["terminals"] as? [[String: Any]] else {
            throw OrcaError.commandFailed("Orca returned no terminal list.")
        }
        return terminals.compactMap { terminal in
            guard terminal["connected"] as? Bool != false,
                  let handle = terminal["handle"] as? String, !handle.isEmpty
            else { return nil }
            return TerminalSurface(
                id: handle,
                name: terminal["title"] as? String ?? "",
                workingDirectory: terminal["worktreePath"] as? String ?? ""
            )
        }
    }

    /// Switches to the tab, then brings Orca to the front. Right after Orca relaunched, it shows its tabs
    /// again before it owns them (`terminal_surface_ownership_unavailable`): the switch is tried again.
    public func focus(terminalID: String) throws {
        for attempt in 1...Self.focusAttempts {
            do {
                _ = try callReportingCode(["terminal", "switch", "--terminal", terminalID])
                break
            } catch let CallFailure.cli(code, message) {
                guard code == "terminal_surface_ownership_unavailable", attempt < Self.focusAttempts else {
                    throw OrcaError.commandFailed(message)
                }
                Thread.sleep(forTimeInterval: retryDelay)
            }
        }
        try activate()
    }

    public func activate() throws {
        let result = try run("/usr/bin/open", ["-a", "Orca"])
        guard result.status == 0 else {
            throw OrcaError.commandFailed(result.error.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Starts Orca when it is not running, adds `directory` to Orca when Orca does not know it, then opens
    /// a focused tab there running `command`, and brings Orca to the front.
    public func openTab(directory: String, command: String, title: String) throws {
        try ensureRunning()
        let selector = "path:\(directory)"
        do {
            _ = try callReportingCode(["worktree", "show", "--worktree", selector])
        } catch let CallFailure.cli(code, _) where code == "selector_not_found" {
            _ = try call(["repo", "add", "--path", directory])
        } catch let CallFailure.cli(_, message) {
            throw OrcaError.commandFailed(message)
        }
        _ = try call([
            "terminal", "create", "--worktree", selector, "--title", title,
            "--command", command, "--focus",
        ])
        // `--focus` selects the tab inside Orca; bring Orca itself to the front so the start shows.
        try activate()
    }

    /// Launches Orca when it is not running, and waits for its runtime (`orca open` does).
    private func ensureRunning() throws {
        guard try !isRunning() else { return }
        _ = try call(["open"])
        guard try isRunning() else { throw OrcaError.notRunning }
    }

    private func isRunning() throws -> Bool {
        let result = try call(["status"])
        let app = result["app"] as? [String: Any]
        let runtime = result["runtime"] as? [String: Any]
        return app?["running"] as? Bool == true && runtime?["reachable"] as? Bool == true
    }

    /// An `ok:false` answer, with Orca's error code so a caller can react to one code.
    private enum CallFailure: Error {
        case cli(code: String, message: String)
    }

    /// Runs `orca <arguments> --json` and returns its `result` object; any failure is `commandFailed`.
    private func call(_ arguments: [String]) throws -> [String: Any] {
        do {
            return try callReportingCode(arguments)
        } catch let CallFailure.cli(_, message) {
            throw OrcaError.commandFailed(message)
        }
    }

    /// Like `call`, but an `ok:false` answer escapes as `CallFailure` with its code.
    private func callReportingCode(_ arguments: [String]) throws -> [String: Any] {
        let result = try run(cli, arguments + ["--json"])
        guard let data = result.output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw OrcaError.commandFailed(detail.isEmpty ? "Orca returned an unreadable answer." : detail)
        }
        guard object["ok"] as? Bool == true else {
            let error = object["error"] as? [String: Any]
            let message = error?["message"] as? String ?? result.error
            throw CallFailure.cli(code: error?["code"] as? String ?? "", message: message)
        }
        return object["result"] as? [String: Any] ?? [:]
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        do {
            return try runner.run(executable, arguments, currentDirectory: nil)
        } catch {
            throw OrcaError.commandFailed("\(error)")
        }
    }
}
