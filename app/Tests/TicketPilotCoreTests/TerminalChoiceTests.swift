import Foundation
import Testing
@testable import TicketPilotCore

@Suite(.timeLimit(.minutes(1))) struct TerminalChoiceTests {
    private let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")

    private func resolve(
        configured: String? = nil,
        host: String? = nil,
        installed: [String] = [],
        systemDefault: URL? = nil
    ) -> TerminalChoice {
        TerminalChoice.resolve(
            configured: configured,
            hostOfRunningClaude: host,
            installedTerminals: installed,
            systemDefault: systemDefault
        )
    }

    @Test func test_configuredNameWinsOverEverything() {
        let choice = resolve(configured: " iTerm ", host: "Ghostty", installed: ["Warp"], systemDefault: terminalURL)
        #expect(choice.appName == "iTerm")
        #expect(!choice.isGhostty)
    }

    @Test func test_blankConfiguredIsIgnored() {
        #expect(resolve(configured: "  ", host: "Ghostty").appName == "Ghostty")
    }

    @Test func test_knownHostOfRunningClaudeComesNext() {
        let choice = resolve(host: "ghostty", installed: ["Ghostty", "Warp"], systemDefault: terminalURL)
        #expect(choice.appName == "Ghostty")
        #expect(choice.isGhostty)
    }

    @Test func test_unknownHostIsSkipped() {
        #expect(resolve(host: "Code", installed: ["Warp"], systemDefault: terminalURL).appName == "Warp")
    }

    @Test func test_singleInstalledKnownTerminalComesNext() {
        #expect(resolve(installed: ["WezTerm"], systemDefault: terminalURL).appName == "WezTerm")
    }

    @Test func test_severalInstalledTerminalsFallToSystemDefault() {
        #expect(resolve(installed: ["Ghostty", "Warp"], systemDefault: terminalURL).appName == "Terminal")
        let other = URL(fileURLWithPath: "/Applications/Foo.app")
        #expect(resolve(installed: ["Ghostty", "Warp"], systemDefault: other).appName == "Foo")
    }

    @Test func test_fallsBackToTerminal() {
        let choice = resolve()
        #expect(choice.appName == "Terminal")
        #expect(!choice.isGhostty)
    }
}

@Suite(.timeLimit(.minutes(1))) struct TerminalDetectorTests {
    @Test func test_hostIsTheKnownAppAboveClaude() {
        let table = """
            1     0 /sbin/launchd
          100     1 /Applications/Ghostty.app/Contents/MacOS/ghostty
          200   100 /usr/bin/login
          300   200 -zsh
          400   300 claude
        """
        #expect(TerminalDetector.host(inProcessTable: table) == "Ghostty")
    }

    @Test func test_pathsWithSpacesAndUnknownHostsAreHandled() {
        let table = """
          100     1 /Applications/Visual Studio Code.app/Contents/MacOS/Electron
          300   100 -zsh
          400   300 claude
        """
        #expect(TerminalDetector.host(inProcessTable: table) == nil)
    }

    @Test func test_noClaudeMeansNoHost() {
        #expect(TerminalDetector.host(inProcessTable: "100 1 /Applications/Ghostty.app/Contents/MacOS/ghostty\n") == nil)
    }

    @Test func test_ghosttyHostedClaudeWinsOverEditorHostedOne() {
        let table = """
          100     1 /Applications/Visual Studio Code.app/Contents/MacOS/Electron
          110   100 -zsh
          120   110 claude
          200     1 /Applications/Ghostty.app/Contents/MacOS/ghostty
          210   200 -zsh
          220   210 /Users/me/.local/bin/claude
        """
        #expect(TerminalDetector.host(inProcessTable: table) == "Ghostty")
    }

    @Test func test_cyclicParentTableTerminates() {
        #expect(TerminalDetector.host(inProcessTable: "10 20 -zsh\n20 10 -zsh\n30 10 claude\n") == nil)
    }

    @Test func test_malformedLinesAreSkipped() {
        let table = """
        garbage
        x y z
        100 1 /Applications/Ghostty.app/Contents/MacOS/ghostty
        400 100 claude
        """
        #expect(TerminalDetector.host(inProcessTable: table) == "Ghostty")
    }

    @Test func test_spacedPathWithKnownTerminal() {
        let table = """
          100     1 /Applications/Some Dir/Ghostty.app/Contents/MacOS/ghostty
          400   100 claude
        """
        #expect(TerminalDetector.host(inProcessTable: table) == "Ghostty")
    }

    @Test func test_iTerm2HostIsCalledITerm() {
        let table = """
          100     1 /Applications/iTerm2.app/Contents/MacOS/iTerm2
          400   100 claude
        """
        #expect(TerminalDetector.host(inProcessTable: table) == "iTerm")
    }

    @Test func test_failingRunnerMeansNoHost() {
        struct Failing: ProcessRunning {
            func run(_ executable: String, _ arguments: [String], currentDirectory: URL?) throws -> ProcessResult {
                ProcessResult(status: 1, output: "100 1 /Applications/Ghostty.app/x\n400 100 claude\n", error: "boom")
            }
        }
        #expect(TerminalDetector(runner: Failing()).hostOfRunningClaude() == nil)
    }

    @Test func test_installedTerminalsComeFromTheApplicationFolders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-apps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Warp.app"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let detector = TerminalDetector(runner: FakeRunner(), applicationDirectories: [dir])
        #expect(detector.installedTerminals() == ["Warp"])
    }

    @Test func test_pickerOffersTheInstalledKnownTerminalsThenTerminal() {
        #expect(TerminalChoice.options(installed: [], configured: nil) == ["Terminal"])
        #expect(TerminalChoice.options(installed: ["warp", "Ghostty"], configured: nil) == ["Ghostty", "Warp", "Terminal"])
        // A configured terminal stays choosable even when it is not a known one.
        #expect(TerminalChoice.options(installed: ["Ghostty"], configured: "Alacritty") == ["Ghostty", "Terminal", "Alacritty"])
        #expect(TerminalChoice.options(installed: ["Ghostty"], configured: "ghostty") == ["Ghostty", "Terminal"])
        #expect(TerminalChoice.options(installed: [], configured: " ") == ["Terminal"])
        let options = ["Ghostty", "Terminal"]
        #expect(TerminalChoice.selectedOption(configured: "ghostty", in: options) == "Ghostty")
        #expect(TerminalChoice.selectedOption(configured: nil, in: options) == nil)
        #expect(TerminalChoice.selectedOption(configured: "  ", in: options) == nil)
    }
}
