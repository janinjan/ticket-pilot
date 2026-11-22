import Foundation
import Testing
@testable import TicketPilotCore

/// Answers each `orca` subcommand ("status", "worktree show", …) with the next scripted result for it;
/// `/usr/bin/open` always succeeds. Records every call.
final class ScriptedOrca: ProcessRunning, @unchecked Sendable {
    struct Call: Equatable { var executable: String; var arguments: [String] }
    private let lock = NSLock()
    private var answers: [String: [ProcessResult]]
    private var stored: [Call] = []
    var calls: [Call] { lock.withLock { stored } }

    init(_ answers: [String: [ProcessResult]]) {
        self.answers = answers
    }

    func run(_ executable: String, _ arguments: [String], currentDirectory: URL?) throws -> ProcessResult {
        lock.withLock {
            stored.append(Call(executable: executable, arguments: arguments))
            guard executable == OrcaControllerTests.cli else { return ProcessResult(status: 0, output: "", error: "") }
            let command = arguments.first == "status" || arguments.first == "open"
                ? arguments[0] : arguments.prefix(2).joined(separator: " ")
            guard var queue = answers[command], !queue.isEmpty else {
                return ProcessResult(status: 1, output: "", error: "unscripted \(command)")
            }
            let next = queue.removeFirst()
            if queue.isEmpty { queue.append(next) }
            answers[command] = queue
            return next
        }
    }
}

@Suite(.timeLimit(.minutes(1))) struct OrcaControllerTests {
    static let cli = "/Apps/Orca.app/Contents/Resources/bin/orca"

    static func ok(_ result: String = "{}") -> ProcessResult {
        ProcessResult(status: 0, output: #"{"ok":true,"result":\#(result)}"#, error: "")
    }

    static func failure(code: String, message: String) -> ProcessResult {
        ProcessResult(status: 1, output: #"{"ok":false,"error":{"code":"\#(code)","message":"\#(message)"}}"#, error: "")
    }

    static func status(running: Bool) -> ProcessResult {
        ok(#"{"app":{"running":\#(running)},"runtime":{"reachable":\#(running)}}"#)
    }

    static let createArguments = [
        "terminal", "create", "--worktree", "path:/r", "--title", "ABC-1 · claude",
        "--command", "cd '/r' && claude", "--focus", "--json",
    ]

    func orcaArguments(_ runner: ScriptedOrca) -> [[String]] {
        runner.calls.filter { $0.executable == Self.cli }.map(\.arguments)
    }

    func openTab(_ runner: ScriptedOrca) throws {
        try OrcaController(runner: runner, cli: Self.cli)
            .openTab(directory: "/r", command: "cd '/r' && claude", title: "ABC-1 · claude")
    }

    @Test func test_listTerminalsMapsHandleTitleAndFolder() throws {
        let runner = ScriptedOrca(["status": [Self.status(running: true)], "terminal list": [Self.ok("""
        {"terminals":[
          {"handle":"term_a","title":"ABC-1 · claude","worktreePath":"/r","connected":true},
          {"handle":"term_b","title":"~","worktreePath":"/Users/me","connected":true}
        ]}
        """)]])
        let terminals = try OrcaController(runner: runner, cli: Self.cli).listTerminals()
        #expect(terminals == [
            TerminalSurface(id: "term_a", name: "ABC-1 · claude", workingDirectory: "/r"),
            TerminalSurface(id: "term_b", name: "~", workingDirectory: "/Users/me"),
        ])
        #expect(orcaArguments(runner) == [["status", "--json"], ["terminal", "list", "--json"]])
    }

    @Test func test_listTerminalsLaunchesOrcaFirst() throws {
        // Quitting Orca keeps its terminals alive (its daemon hosts them): Orca reopens them, so the list is
        // read once Orca runs again, and a live session is found instead of being started twice.
        let runner = ScriptedOrca([
            "status": [Self.status(running: false), Self.status(running: true)],
            "open": [Self.ok()],
            "terminal list": [Self.ok(#"{"terminals":[{"handle":"term_a","title":"ABC-1 ticket","worktreePath":"/r"}]}"#)],
        ])
        let terminals = try OrcaController(runner: runner, cli: Self.cli).listTerminals()
        #expect(terminals.map(\.id) == ["term_a"])
        #expect(orcaArguments(runner) == [
            ["status", "--json"], ["open", "--json"], ["status", "--json"], ["terminal", "list", "--json"],
        ])
    }

    @Test func test_listTerminalsThrowsNotRunningWhenOrcaNeverStarts() throws {
        let runner = ScriptedOrca(["status": [Self.status(running: false)], "open": [Self.ok()]])
        #expect(throws: OrcaError.notRunning) { try OrcaController(runner: runner, cli: Self.cli).listTerminals() }
    }

    @Test func test_alertKeyOfCommandFailureIncludesItsMessage() {
        // Orca has no fallback: a new failure must show, even of a kind already reported.
        #expect(OrcaError.commandFailed("a").alertKey != OrcaError.commandFailed("b").alertKey)
        #expect(OrcaError.notRunning.alertKey == "notRunning")
        #expect(GhosttyError.timedOut.alertKey == GhosttyError.timedOut.kind)
    }

    @Test func test_listTerminalsSkipsDisconnected() throws {
        let runner = ScriptedOrca(["status": [Self.status(running: true)], "terminal list": [Self.ok("""
        {"terminals":[{"handle":"term_a","title":"ABC-1 · claude","worktreePath":"/r","connected":false}]}
        """)]])
        #expect(try OrcaController(runner: runner, cli: Self.cli).listTerminals().isEmpty)
    }

    @Test func test_focusSwitchesThenActivates() throws {
        let runner = ScriptedOrca(["terminal switch": [Self.ok()]])
        try OrcaController(runner: runner, cli: Self.cli).focus(terminalID: "term_a")
        #expect(runner.calls == [
            .init(executable: Self.cli, arguments: ["terminal", "switch", "--terminal", "term_a", "--json"]),
            .init(executable: "/usr/bin/open", arguments: ["-a", "Orca"]),
        ])
    }

    @Test func test_focusRetriesWhileOrcaIsStillAdoptingItsTabs() throws {
        // Right after a relaunch, Orca refuses to switch to a tab it shows again until it owns it.
        let busy = Self.failure(code: "terminal_surface_ownership_unavailable", message: "terminal_surface_ownership_unavailable")
        let runner = ScriptedOrca(["terminal switch": [busy, busy, Self.ok()]])
        try OrcaController(runner: runner, cli: Self.cli, retryDelay: 0).focus(terminalID: "term_a")
        #expect(orcaArguments(runner).filter { $0.prefix(2) == ["terminal", "switch"] }.count == 3)
        #expect(runner.calls.last == .init(executable: "/usr/bin/open", arguments: ["-a", "Orca"]))
    }

    @Test func test_focusGivesUpAfterItsRetries() throws {
        let busy = Self.failure(code: "terminal_surface_ownership_unavailable", message: "terminal_surface_ownership_unavailable")
        let runner = ScriptedOrca(["terminal switch": [busy]])
        #expect(throws: OrcaError.commandFailed("terminal_surface_ownership_unavailable")) {
            try OrcaController(runner: runner, cli: Self.cli, retryDelay: 0).focus(terminalID: "term_a")
        }
        #expect(orcaArguments(runner).count == OrcaController.focusAttempts)
    }

    @Test func test_openTabWhenRunningAndKnown() throws {
        let runner = ScriptedOrca([
            "status": [Self.status(running: true)],
            "worktree show": [Self.ok()],
            "terminal create": [Self.ok()],
        ])
        try openTab(runner)
        #expect(orcaArguments(runner) == [
            ["status", "--json"],
            ["worktree", "show", "--worktree", "path:/r", "--json"],
            Self.createArguments,
        ])
        // The new tab shows only once Orca itself is in front.
        #expect(runner.calls.last == .init(executable: "/usr/bin/open", arguments: ["-a", "Orca"]))
    }

    @Test func test_openTabLaunchesOrcaWhenNotRunning() throws {
        let runner = ScriptedOrca([
            "status": [Self.status(running: false), Self.status(running: true)],
            "open": [Self.ok()],
            "worktree show": [Self.ok()],
            "terminal create": [Self.ok()],
        ])
        try openTab(runner)
        #expect(orcaArguments(runner) == [
            ["status", "--json"],
            ["open", "--json"],
            ["status", "--json"],
            ["worktree", "show", "--worktree", "path:/r", "--json"],
            Self.createArguments,
        ])
    }

    @Test func test_openTabThrowsNotRunningWhenOrcaNeverStarts() throws {
        let runner = ScriptedOrca(["status": [Self.status(running: false)], "open": [Self.ok()]])
        #expect(throws: OrcaError.notRunning) { try openTab(runner) }
        #expect(!orcaArguments(runner).contains(Self.createArguments))
    }

    @Test func test_openTabRegistersUnknownRepo() throws {
        let runner = ScriptedOrca([
            "status": [Self.status(running: true)],
            "worktree show": [Self.failure(code: "selector_not_found", message: "selector_not_found")],
            "repo add": [Self.ok()],
            "terminal create": [Self.ok()],
        ])
        try openTab(runner)
        #expect(orcaArguments(runner) == [
            ["status", "--json"],
            ["worktree", "show", "--worktree", "path:/r", "--json"],
            ["repo", "add", "--path", "/r", "--json"],
            Self.createArguments,
        ])
    }

    @Test func test_commandFailureCarriesCLIMessage() throws {
        let runner = ScriptedOrca([
            "status": [Self.status(running: true)],
            "worktree show": [Self.ok()],
            "terminal create": [Self.failure(code: "x", message: "boom")],
        ])
        #expect(throws: OrcaError.commandFailed("boom")) { try openTab(runner) }
    }

    @Test func test_unreadableOutputIsCommandFailure() throws {
        let runner = ScriptedOrca([
            "status": [Self.status(running: true)],
            "terminal list": [ProcessResult(status: 0, output: "not json", error: "")],
        ])
        #expect {
            try OrcaController(runner: runner, cli: Self.cli).listTerminals()
        } throws: { error in
            if case .commandFailed = error as? OrcaError { return true }
            return false
        }
    }

    @Test func test_cliPathFindsBundledBinary() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-orca-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(OrcaController.cliPath(applicationDirectories: [dir]) == nil)
        let bin = dir.appendingPathComponent("Orca.app/Contents/Resources/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin.appendingPathComponent("orca").path, contents: Data())
        #expect(OrcaController.cliPath(applicationDirectories: [dir]) == bin.appendingPathComponent("orca").path)
    }

    @Test func test_neverTypesIntoOrClosesATerminal() throws {
        let runner = ScriptedOrca([
            "status": [Self.status(running: false), Self.status(running: true)],
            "open": [Self.ok()],
            "worktree show": [Self.failure(code: "selector_not_found", message: "selector_not_found")],
            "repo add": [Self.ok()],
            "terminal create": [Self.ok()],
            "terminal list": [Self.ok(#"{"terminals":[]}"#)],
            "terminal switch": [Self.ok()],
        ])
        let controller = OrcaController(runner: runner, cli: Self.cli)
        try openTab(runner)
        _ = try controller.listTerminals()
        try controller.focus(terminalID: "term_a")
        try controller.activate()
        for arguments in orcaArguments(runner) {
            #expect(Array(arguments.prefix(2)) != ["terminal", "send"])
            #expect(Array(arguments.prefix(2)) != ["terminal", "close"])
        }
    }
}
