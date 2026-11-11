import Foundation
import Testing
@testable import TicketPilotCore

@Suite(.timeLimit(.minutes(1))) struct SessionLocatorTests {
    private static func run(cwd: String?, worktree: String?, repoPath: String) -> Run {
        Run(
            id: "ABC-1--ios", key: "ABC-1", repo: "ios", repoPath: repoPath, worktree: worktree, branch: nil,
            sessionID: "s1",
            session: Run.SessionInfo(state: "waiting", lastNotification: nil, notifiedAt: nil, cwd: cwd),
            step: 1, stepName: "Read", status: .waiting, waiting: nil, history: [],
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private static func surface(_ id: String, _ name: String, _ directory: String) -> TerminalSurface {
        TerminalSurface(id: id, name: name, workingDirectory: directory)
    }

    @Test func foldersAreSessionCwdThenWorktreeThenRepo() {
        let folders = SessionLocator.candidateFolders(for: Self.run(cwd: "/w/sub", worktree: "/w", repoPath: "/r"))
        #expect(folders == ["/w/sub", "/w", "/r"])
    }

    @Test func foldersDropMissingAndDuplicateEntries() {
        let folders = SessionLocator.candidateFolders(for: Self.run(cwd: "/w/", worktree: "/w", repoPath: "/w/./"))
        #expect(folders == ["/w"])
        #expect(SessionLocator.candidateFolders(for: Self.run(cwd: nil, worktree: nil, repoPath: "/r")) == ["/r"])
    }

    @Test func earliestFolderWins() {
        let terminals = [Self.surface("a", "zsh", "/r"), Self.surface("b", "zsh", "/w")]
        #expect(SessionLocator.pickTerminal(terminals, folders: ["/w", "/r"]) == "b")
    }

    @Test func claudeLookingTitlePreferredInTheSameFolder() {
        let terminals = [
            Self.surface("a", "zsh", "/w"),
            Self.surface("b", "✳ Fix the bug", "/w"),
            Self.surface("c", "Claude Code", "/w"),
        ]
        #expect(SessionLocator.pickTerminal(terminals, folders: ["/w"]) == "b")
        #expect(SessionLocator.pickTerminal([terminals[0], terminals[2]], folders: ["/w"]) == "c")
    }

    @Test func spinnerGlyphsAreRecognised() {
        for glyph in ["✳", "✻", "◐", "◑", "◒", "◓"] {
            let terminals = [Self.surface("a", "zsh", "/w"), Self.surface("b", "\(glyph) work", "/w")]
            #expect(SessionLocator.pickTerminal(terminals, folders: ["/w"]) == "b")
        }
    }

    @Test func claudeMustBeAWholeWordInTheTitle() {
        for title in ["claude-tools", "~/claude-tools", "myclaude", "claude_x", "zsh ~/claude.d"] {
            let terminals = [Self.surface("a", "zsh", "/w"), Self.surface("b", title, "/w")]
            #expect(SessionLocator.pickTerminal(terminals, folders: ["/w"], claudeOnly: true) == nil, "\(title)")
        }
        for title in ["Claude Code", "CLAUDE", "node (claude)", "x - claude"] {
            let terminals = [Self.surface("b", title, "/w")]
            #expect(SessionLocator.pickTerminal(terminals, folders: ["/w"], claudeOnly: true) == "b", "\(title)")
        }
    }

    @Test func firstTerminalWhenNoneLooksLikeClaude() {
        let terminals = [Self.surface("a", "zsh", "/w"), Self.surface("b", "vim", "/w")]
        #expect(SessionLocator.pickTerminal(terminals, folders: ["/w"]) == "a")
    }

    @Test func claudeOnlyIgnoresPlainShells() {
        let shell = [Self.surface("a", "zsh", "/w")]
        #expect(SessionLocator.pickTerminal(shell, folders: ["/w"], claudeOnly: true) == nil)
        #expect(SessionLocator.pickTerminal(shell, folders: ["/w"]) == "a")
        let mixed = [Self.surface("a", "zsh", "/w"), Self.surface("b", "✻ work", "/w")]
        #expect(SessionLocator.pickTerminal(mixed, folders: ["/w"], claudeOnly: true) == "b")
        let later = [Self.surface("a", "zsh", "/w"), Self.surface("b", "claude", "/r")]
        #expect(SessionLocator.pickTerminal(later, folders: ["/w", "/r"], claudeOnly: true) == "b")
    }

    @Test func noMatchIsNil() {
        #expect(SessionLocator.pickTerminal([Self.surface("a", "zsh", "/x")], folders: ["/w"]) == nil)
        #expect(SessionLocator.pickTerminal([], folders: ["/w"]) == nil)
        #expect(SessionLocator.pickTerminal([Self.surface("a", "zsh", "/w")], folders: []) == nil)
    }

    @Test func terminalDirectoryIsStandardizedBeforeComparing() {
        #expect(SessionLocator.pickTerminal([Self.surface("a", "zsh", "/w/")], folders: ["/w"]) == "a")
    }

    @Test func sessionCwdDecodesAndIsTolerant() throws {
        func decode(_ session: String) throws -> Run {
            let json = """
            {"id":"A-1--x","key":"A-1","repo":"x","repo_path":"/r","step":1,"step_name":"s","status":"running",
             "updated_at":"2026-01-01T00:00:00Z","session":\(session)}
            """
            return try JSONDecoder.runDecoder.decode(Run.self, from: Data(json.utf8))
        }
        #expect(try decode(#"{"state":"waiting","cwd":"/w"}"#).session?.cwd == "/w")
        #expect(try decode(#"{"state":"waiting"}"#).session?.cwd == nil)
        let bad = try decode(#"{"state":"waiting","cwd":5}"#)
        #expect(bad.session?.state == "waiting")
        #expect(bad.session?.cwd == nil)
    }
}

@Suite(.timeLimit(.minutes(1))) struct GhosttyControllerTests {
    final class Runner: ProcessRunning, @unchecked Sendable {
        var result: ProcessResult
        var calls: [(String, [String])] = []
        init(_ result: ProcessResult) { self.result = result }
        func run(_ executable: String, _ arguments: [String], currentDirectory: URL?) throws -> ProcessResult {
            calls.append((executable, arguments))
            return result
        }
    }

    @Test func listParsesRecords() throws {
        let output = "1\u{1F}✳ Fix\u{1F}/w\u{1E}\n2\u{1F}a\tb\nc\u{1F}/r\u{1E}\n"
        let runner = Runner(ProcessResult(status: 0, output: output, error: ""))
        let terminals = try GhosttyController(runner: runner).listTerminals()
        #expect(terminals == [
            TerminalSurface(id: "1", name: "✳ Fix", workingDirectory: "/w"),
            TerminalSurface(id: "2", name: "a\tb\nc", workingDirectory: "/r"),
        ])
        #expect(runner.calls.first?.0 == "/usr/bin/osascript")
    }

    @Test func listSkipsMalformedRecordsAndAcceptsEmpty() throws {
        let runner = Runner(ProcessResult(status: 0, output: "garbage\u{1E}\n3\u{1F}n\u{1F}/w\u{1E}\n", error: ""))
        #expect(try GhosttyController(runner: runner).listTerminals().map(\.id) == ["3"])
        runner.result = ProcessResult(status: 0, output: "\n", error: "")
        #expect(try GhosttyController(runner: runner).listTerminals().isEmpty)
    }

    @Test func permissionRefusalIsReported() {
        let runner = Runner(ProcessResult(status: 1, output: "", error: "execution error: Not authorized (-1743)"))
        #expect(throws: GhosttyError.permissionDenied) { try GhosttyController(runner: runner).listTerminals() }
    }

    @Test func otherFailureCarriesTheMessage() {
        let runner = Runner(ProcessResult(status: 1, output: "", error: "boom\n"))
        #expect(throws: GhosttyError.scriptFailed("boom")) { try GhosttyController(runner: runner).listTerminals() }
    }

    @Test func focusEscapesTheIdentifier() throws {
        let runner = Runner(ProcessResult(status: 0, output: "", error: ""))
        try GhosttyController(runner: runner).focus(terminalID: #"a"b\c"#)
        let script = runner.calls[0].1.joined(separator: " ")
        #expect(script.contains(#""a\"b\\c""#))
        #expect(!runner.calls[0].1.contains("sh"))
    }

    @Test func openTabEscapesFolderAndCommand() throws {
        let runner = Runner(ProcessResult(status: 0, output: "", error: ""))
        try GhosttyController(runner: runner).openTab(directory: #"/w "x""#, command: #"echo "hi" \"#)
        let script = runner.calls[0].1.joined(separator: " ")
        #expect(script.contains(#"initial working directory:"/w \"x\"""#))
        #expect(script.contains(#""echo \"hi\" \\" & linefeed"#))
        #expect(script.contains("new tab"))
    }

    @Test func scriptsNeverTypeIntoOrCloseATerminal() throws {
        let runner = Runner(ProcessResult(status: 0, output: "", error: ""))
        let controller = GhosttyController(runner: runner)
        _ = try controller.listTerminals()
        try controller.focus(terminalID: "1")
        try controller.openTab(directory: "/w", command: "claude --resume s1")
        #expect(runner.calls.count == 3)
        for call in runner.calls {
            let script = call.1.joined(separator: " ").lowercased()
            for forbidden in ["input text", "send key", "close"] {
                #expect(!script.contains(forbidden), "\(forbidden)")
            }
        }
    }

    @Test func timeoutIsReportedAsAutomationPrompt() {
        let runner = Runner(ProcessResult(status: 1, output: "", error: "timed out after 20.0 seconds"))
        #expect(throws: GhosttyError.timedOut) { try GhosttyController(runner: runner).listTerminals() }
        #expect(GhosttyError.timedOut.alertText.message.contains("Automation"))
    }

    @Test func alertMentionsAutomationSettings() {
        #expect(GhosttyError.permissionDenied.alertText.message.contains("Automation"))
    }

    @Test func theTabTitledWithTheKeyWinsWhateverItsFolder() {
        // A tab opened by Start reports the launcher's scripts folder: only its title names the run.
        let terminals = [
            TerminalSurface(id: "a", name: "◑ État d'avancement et problèmes", workingDirectory: "/Users/me/Developer"),
            TerminalSurface(id: "b", name: "✳ ABC-3277 Jira ticket", workingDirectory: "/Users/me/Library/Application Support/ticket-pilot/app/scripts"),
        ]
        #expect(SessionLocator.pickTerminal(terminals, key: "ABC-3277", folders: ["/r"], claudeOnly: true) == "b")
        #expect(SessionLocator.pickTerminal(terminals, key: "ABC-3277", folders: ["/r"]) == "b")
    }

    @Test func theKeyMustBeAWholeToken() {
        let terminals = [
            TerminalSurface(id: "a", name: "✳ ABC-32770 other", workingDirectory: "/x"),
            TerminalSurface(id: "b", name: "✳ XABC-3277 other", workingDirectory: "/x"),
            TerminalSurface(id: "c", name: "✳ abc-3277 lower case", workingDirectory: "/x"),
        ]
        #expect(SessionLocator.pickTerminal(terminals, key: "ABC-3277", folders: ["/r"]) == nil)
        #expect(SessionLocator.pickTerminal([TerminalSurface(id: "d", name: "ABC-3277: Jira", workingDirectory: "/x")], key: "ABC-3277", folders: []) == "d")
    }

    @Test func amongKeyTitledTabsTheOneInTheRunsFolderThenAClaudeOneWins() {
        let terminals = [
            TerminalSurface(id: "a", name: "less ABC-1 notes", workingDirectory: "/x"),
            TerminalSurface(id: "b", name: "✳ ABC-1 android", workingDirectory: "/android"),
            TerminalSurface(id: "c", name: "✳ ABC-1 ios", workingDirectory: "/w"),
        ]
        #expect(SessionLocator.pickTerminal(terminals, key: "ABC-1", folders: ["/w", "/r"]) == "c")
        #expect(SessionLocator.pickTerminal(terminals, key: "ABC-1", folders: ["/r"]) == "b")
        // A plain shell naming the key is not the session when only a Claude Code tab will do.
        #expect(SessionLocator.pickTerminal([terminals[0]], key: "ABC-1", folders: ["/r"], claudeOnly: true) == nil)
    }

    private static let tabs = [
        TerminalSurface(id: "a", name: "◑ État d'avancement", workingDirectory: "/x"),
        TerminalSurface(id: "b", name: "✳ ABC-1 ios", workingDirectory: "/y"),
    ]

    @Test func aMatchingTabIsFocusedWhateverTheSessionState() {
        for action in [SessionAction.bringToFront, .resume] {
            #expect(action.ghosttyOutcome(terminals: Self.tabs, key: "ABC-1", folders: ["/r"]) == .focus(terminalID: "b"))
        }
    }

    @Test func aRunningSessionWithNoTabIsResumedInANewTab() {
        #expect(SessionAction.bringToFront.ghosttyOutcome(terminals: Self.tabs, key: "ABC-2", folders: ["/r"]) == .openNewTab)
        #expect(SessionAction.bringToFront.ghosttyOutcome(terminals: [], key: "ABC-2", folders: ["/r"]) == .openNewTab)
        #expect(SessionAction.resume.ghosttyOutcome(terminals: Self.tabs, key: "ABC-2", folders: ["/r"]) == .openNewTab)
    }

    @Test func aLiveSessionIsNeverDuplicatedWhenTheTabListCannotBeRead() {
        #expect(SessionAction.bringToFront.ghosttyOutcome(terminals: nil, key: "ABC-1", folders: []) == .bringGhosttyToFront)
        #expect(SessionAction.resume.ghosttyOutcome(terminals: nil, key: "ABC-1", folders: []) == .openNewTab)
    }
}
