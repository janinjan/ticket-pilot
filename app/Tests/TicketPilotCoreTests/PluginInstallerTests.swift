import Foundation
import Testing
@testable import TicketPilotCore

/// Answers `marketplace list` with `listOutput`, every other command with success unless it is `failing`.
private final class FakeClaude: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    let listOutput: String
    let listStatus: Int32
    let failing: [String]?

    init(listOutput: String, listStatus: Int32 = 0, failing: [String]? = nil) {
        self.listOutput = listOutput
        self.listStatus = listStatus
        self.failing = failing
    }

    var calls: [[String]] { lock.withLock { recorded } }

    func run(_ executable: String, _ arguments: [String], currentDirectory: URL?) throws -> ProcessResult {
        #expect(executable == "/bin/claude")
        lock.withLock { recorded.append(arguments) }
        if arguments == ["plugin", "marketplace", "list", "--json"] {
            return ProcessResult(status: listStatus, output: listOutput, error: listStatus == 0 ? "" : "list broke")
        }
        if arguments == failing {
            return ProcessResult(status: 1, output: "partial", error: "network down")
        }
        return ProcessResult(status: 0, output: "ok: " + arguments.joined(separator: " "), error: "")
    }
}

@Suite(.timeLimit(.minutes(1))) struct PluginInstallerTests {
    static let bundled = URL(fileURLWithPath: "/Applications/TicketPilot.app/Contents/Resources/plugin")
    static let withMarketplace = """
    [{"name":"claude-plugins-official","source":"github"},
     {"name":"ticket-pilot","source":"github","repo":"someone/ticket-pilot"}]
    """
    static let withoutMarketplace = #"[{"name":"claude-plugins-official","source":"github"}]"#

    fileprivate func installer(_ runner: FakeClaude, bundled: URL? = bundled) -> PluginInstaller {
        PluginInstaller(claudePath: "/bin/claude", bundledPlugin: bundled, runner: runner)
    }

    @Test func test_configuredMarketplaceAndInstalledPluginUpdatesBoth() throws {
        let runner = FakeClaude(listOutput: Self.withMarketplace)
        let plan = try installer(runner).plan(pluginInstalled: true)
        #expect(plan.map(\.arguments) == [
            ["plugin", "marketplace", "update", "ticket-pilot"],
            ["plugin", "update", "ticket-pilot@ticket-pilot"],
        ])
        #expect(runner.calls == [["plugin", "marketplace", "list", "--json"]])
    }

    @Test func test_configuredMarketplaceWithoutPluginUpdatesItThenInstalls() throws {
        let runner = FakeClaude(listOutput: Self.withMarketplace)
        let plan = try installer(runner).plan(pluginInstalled: false)
        #expect(plan.map(\.arguments) == [
            ["plugin", "marketplace", "update", "ticket-pilot"],
            ["plugin", "install", "ticket-pilot@ticket-pilot"],
        ])
    }

    @Test func test_noMarketplaceAddsTheBundledCopyThenInstalls() throws {
        let runner = FakeClaude(listOutput: Self.withoutMarketplace)
        let plan = try installer(runner).plan(pluginInstalled: false)
        #expect(plan.map(\.arguments) == [
            ["plugin", "marketplace", "add", Self.bundled.path],
            ["plugin", "install", "ticket-pilot@ticket-pilot"],
        ])
        #expect(plan.map(\.display) == [
            "claude plugin marketplace add '/Applications/TicketPilot.app/Contents/Resources/plugin'",
            "claude plugin install ticket-pilot@ticket-pilot",
        ])
    }

    @Test func test_noMarketplaceAndNoBundledCopyCannotInstall() {
        let runner = FakeClaude(listOutput: "[]")
        #expect(throws: PluginInstallError.noBundledPlugin) {
            try installer(runner, bundled: nil).plan(pluginInstalled: false)
        }
    }

    @Test func test_aFailedListIsReported() {
        let runner = FakeClaude(listOutput: "", listStatus: 1)
        #expect(throws: PluginInstallError.commandFailed(
            command: "claude plugin marketplace list --json", error: "list broke", completed: []
        )) {
            try installer(runner).plan(pluginInstalled: false)
        }
    }

    @Test func test_anUnreadableListIsReported() {
        let runner = FakeClaude(listOutput: "Configured marketplaces:")
        #expect(throws: PluginInstallError.unreadableMarketplaceList) {
            try installer(runner).plan(pluginInstalled: false)
        }
    }

    @Test func test_runReturnsEachCommandsOutput() throws {
        let runner = FakeClaude(listOutput: Self.withoutMarketplace)
        let installer = installer(runner)
        let results = try installer.run(try installer.plan(pluginInstalled: false))
        #expect(results.map(\.command.display) == [
            "claude plugin marketplace add '/Applications/TicketPilot.app/Contents/Resources/plugin'",
            "claude plugin install ticket-pilot@ticket-pilot",
        ])
        #expect(results.map(\.output) == [
            "ok: plugin marketplace add /Applications/TicketPilot.app/Contents/Resources/plugin",
            "ok: plugin install ticket-pilot@ticket-pilot",
        ])
    }

    @Test func test_runStopsAtTheFirstFailureWithItsStderr() throws {
        let runner = FakeClaude(
            listOutput: Self.withMarketplace, failing: ["plugin", "marketplace", "update", "ticket-pilot"]
        )
        let installer = installer(runner)
        let plan = try installer.plan(pluginInstalled: true)
        #expect(throws: PluginInstallError.commandFailed(
            command: "claude plugin marketplace update ticket-pilot", error: "network down", completed: []
        )) {
            try installer.run(plan)
        }
        // The update after the failed step never runs.
        #expect(!runner.calls.contains(["plugin", "update", "ticket-pilot@ticket-pilot"]))
    }

    @Test func test_failureAlertNamesTheCommandAndItsStderr() {
        let error = PluginInstallError.commandFailed(
            command: "claude plugin install ticket-pilot@ticket-pilot", error: "network down\n", completed: []
        )
        #expect(error.alertText == AlertText(
            title: "The plugin was not installed",
            message: "claude plugin install ticket-pilot@ticket-pilot failed:\n\nnetwork down"
        ))
    }

    /// Plain words for someone who never typed a `claude plugin` command: what it is for, its version.
    @Test func test_confirmationSaysWhatThePluginIsFor() throws {
        let runner = FakeClaude(listOutput: Self.withMarketplace)
        let install = try installer(runner).plan(pluginInstalled: false)
        #expect(PluginInstaller.confirmation(install, version: "0.5.0") == AlertText(
            title: "Install the TicketPilot plugin?",
            message: "Claude Code needs it to work on your tickets.\nVersion 0.5.0."
        ))
        #expect(PluginInstaller.confirmation(install, version: nil).message == "Claude Code needs it to work on your tickets.")
        #expect(PluginInstaller.confirmButton(install) == "Install")
        let update = try installer(runner).plan(pluginInstalled: true)
        #expect(PluginInstaller.confirmation(update, version: "0.5.0") == AlertText(
            title: "Update the TicketPilot plugin?",
            message: "Version 0.5.0 is ready for Claude Code."
        ))
        #expect(PluginInstaller.confirmButton(update) == "Update")
    }

    @Test func test_successSaysWhatToDoNext() throws {
        let runner = FakeClaude(listOutput: Self.withMarketplace)
        #expect(PluginInstaller.success(try installer(runner).plan(pluginInstalled: false), version: "0.5.0") == AlertText(
            title: "TicketPilot plugin 0.5.0 installed",
            message: "Tickets you start from TicketPilot use it. A Claude Code session already open sees it after a restart."
        ))
        #expect(PluginInstaller.success(try installer(runner).plan(pluginInstalled: true), version: "0.5.0").title
            == "TicketPilot plugin updated to 0.5.0")
        #expect(PluginInstaller.success(try installer(runner).plan(pluginInstalled: false), version: nil).title
            == "TicketPilot plugin installed")
    }
}
