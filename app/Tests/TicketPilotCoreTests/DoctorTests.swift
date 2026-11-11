import Foundation
import Testing
@testable import TicketPilotCore

private final class FakeJira: JiraSearching, @unchecked Sendable {
    let outcome: JiraError?
    init(_ outcome: JiraError? = nil) { self.outcome = outcome }
    func openAssignedIssues() async throws(JiraError) -> [JiraIssue] { [] }
    func statusCategories(of keys: [String]) async throws(JiraError) -> [String: JiraIssue.StatusCategory] { [:] }
    func checkCredentials() async throws(JiraError) {
        if let outcome { throw outcome }
    }
}

private final class MCPRunner: ProcessRunning, @unchecked Sendable {
    var result: Result<ProcessResult, any Error>
    init(output: String = "", status: Int32 = 0) {
        result = .success(ProcessResult(status: status, output: output, error: ""))
    }
    func run(_ executable: String, _ arguments: [String], currentDirectory: URL?) throws -> ProcessResult {
        try result.get()
    }
}

private struct TokenError: Error {}

@Suite struct DoctorTests {
    struct Fixture {
        var home: URL
        var claude: String
        var repoPaths: [String: String]
        var bundledManifest: URL
    }

    func makeFixture(
        claude: Bool = true, plugin: Bool = true, installedVersion: String = "0.4.2", bundledVersion: String? = "0.4.2",
        existingRepos: Bool = true
    ) throws -> Fixture {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tp-doctor-\(UUID().uuidString)")
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let claudePath = bin.appendingPathComponent("claude").path
        if claude {
            try "#!/bin/sh\n".write(toFile: claudePath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claudePath)
        }
        if plugin {
            let dir = home.appendingPathComponent(".claude/plugins")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let json = #"{"version":2,"plugins":{"ticket-pilot@ticket-pilot":[{"scope":"user","version":"\#(installedVersion)"}]}}"#
            try json.write(to: dir.appendingPathComponent("installed_plugins.json"), atomically: true, encoding: .utf8)
        }
        var paths: [String: String] = [:]
        for name in ["ios", "web"] {
            let url = home.appendingPathComponent("repos/\(name)")
            if existingRepos || name != "ios" {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            paths[name] = url.path
        }
        let manifest = home.appendingPathComponent("bundle/plugin/.claude-plugin/plugin.json")
        if let bundledVersion {
            try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try #"{"name":"ticket-pilot","version":"\#(bundledVersion)"}"#.write(to: manifest, atomically: true, encoding: .utf8)
        }
        return Fixture(home: home, claude: claudePath, repoPaths: paths, bundledManifest: manifest)
    }

    func makeConfig(_ fixture: Fixture) throws -> AppConfig {
        let repos = ["ios", "web"].map {
            #"{"name":"\#($0)","path":"\#(fixture.repoPaths[$0]!)","main_branch":"main","review":"none"}"#
        }
        let json = """
        {"jira":{"site":"https://example.atlassian.net","email":"me@example.com","keychain_service":"tp-test"},
         "repos":[\(repos.joined(separator: ","))]}
        """
        return try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    }

    func makeDoctor(
        _ fixture: Fixture,
        runner: ProcessRunning = MCPRunner(output: "atlassian: https://x - ✓ Connected\nfigma: https://y - ✓ Connected\n"),
        jira: JiraSearching? = FakeJira(),
        token: @escaping @Sendable () throws -> String = { "secret" },
        freeBytes: Int64? = 100_000_000_000
    ) throws -> Doctor {
        Doctor(
            config: try makeConfig(fixture),
            home: fixture.home,
            runner: runner,
            jira: jira,
            tokenLookup: token,
            freeBytes: { freeBytes },
            claudeSearchPaths: [fixture.claude],
            bundledPluginManifest: fixture.bundledManifest
        )
    }

    func check(_ checks: [HealthCheck], _ kind: HealthCheck.Kind) throws -> HealthCheck {
        try #require(checks.first { $0.id == kind })
    }

    @Test func allGreen() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let checks = await (try makeDoctor(fixture)).run()
        #expect(checks.map(\.id) == [.claudeCLI, .plugin, .jiraToken, .jiraReachable, .mcp, .repoPaths, .diskSpace])
        let allOk = checks.allSatisfy { $0.ok }
        #expect(allOk)
        #expect(checks.allSatisfy { $0.ok })
        #expect(checks.canStart(repo: "ios"))
        let plugin = try check(checks, .plugin)
        #expect(plugin.detail == "installed 0.4.2 · bundled 0.4.2")
        #expect(plugin.pluginState == .current)
    }

    @Test func missingClaudeBlocksEveryStart() async throws {
        let fixture = try makeFixture(claude: false)
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let checks = await (try makeDoctor(fixture)).run()
        let claude = try check(checks, .claudeCLI)
        #expect(!claude.ok)
        #expect(claude.blocksStart)
        #expect(claude.fix == "Install Claude Code: https://docs.claude.com/claude-code")
        #expect(!checks.canStart(repo: "ios"))
        #expect(!checks.canStart(repo: "web"))
        let mcp = try check(checks, .mcp)
        #expect(!mcp.ok)
        #expect(!mcp.blocksStart)
        #expect(mcp.detail == "claude not found")
    }

    @Test func missingPluginBlocks() async throws {
        let fixture = try makeFixture(plugin: false)
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let checks = await (try makeDoctor(fixture)).run()
        let plugin = try check(checks, .plugin)
        #expect(!plugin.ok)
        #expect(plugin.blocksStart)
        #expect(plugin.fix == "claude plugin install ticket-pilot@ticket-pilot")
        #expect(plugin.pluginState == .missing)
        #expect(plugin.detail == "not installed · bundled 0.4.2")
        #expect(!checks.canStart(repo: "web"))
    }

    @Test func olderPluginIsOutdatedButDoesNotBlock() async throws {
        let fixture = try makeFixture(installedVersion: "0.1.2", bundledVersion: "0.1.10")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let checks = await (try makeDoctor(fixture)).run()
        let plugin = try check(checks, .plugin)
        #expect(!plugin.ok)
        #expect(!plugin.blocksStart)
        #expect(plugin.pluginState == .outdated(installed: "0.1.2", bundled: "0.1.10"))
        #expect(plugin.detail == "installed 0.1.2 · bundled 0.1.10")
        #expect(checks.canStart(repo: "web"))
    }

    @Test func newerPluginThanBundledIsFine() async throws {
        let fixture = try makeFixture(installedVersion: "0.2.0", bundledVersion: "0.1.3")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let plugin = try check(await (try makeDoctor(fixture)).run(), .plugin)
        #expect(plugin.ok)
        #expect(plugin.pluginState == .newerThanBundled)
    }

    @Test func noBundledCopyStillAcceptsAnInstalledPlugin() async throws {
        let fixture = try makeFixture(bundledVersion: nil)
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let plugin = try check(await (try makeDoctor(fixture)).run(), .plugin)
        #expect(plugin.ok)
        #expect(plugin.pluginState == .unknown)
        #expect(plugin.detail == "installed 0.4.2 · bundled none")
    }

    @Test func claudePathComesFromTheClaudeCheck() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        #expect(await (try makeDoctor(fixture)).run().claudePath == fixture.claude)
        let missing = try makeFixture(claude: false)
        defer { try? FileManager.default.removeItem(at: missing.home) }
        #expect(await (try makeDoctor(missing)).run().claudePath == nil)
    }

    @Test func missingTokenBlocksWithKeychainFix() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let checks = await (try makeDoctor(fixture, jira: nil, token: { throw TokenError() })).run()
        let token = try check(checks, .jiraToken)
        #expect(!token.ok)
        #expect(token.blocksStart)
        let fix = try #require(token.fix)
        #expect(fix.contains("tp-test"))
        #expect(token.fix == #"security add-generic-password -s "tp-test" -a "$USER" -w"#)
        let reachable = try check(checks, .jiraReachable)
        #expect(!reachable.ok)
        #expect(!reachable.blocksStart)
        #expect(reachable.detail == "not checked: no Jira token")
    }

    @Test func unauthorizedVersusUnreachable() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let unauthorized = await (try makeDoctor(fixture, jira: FakeJira(.unauthorized))).run()
        let unreachable = await (try makeDoctor(fixture, jira: FakeJira(.unreachable))).run()

        let refused = try check(unauthorized, .jiraToken)
        #expect(!refused.ok)
        #expect(refused.blocksStart)
        let answered = try check(unauthorized, .jiraReachable)
        #expect(answered.ok)

        let tokenStillFine = try check(unreachable, .jiraToken)
        #expect(tokenStillFine.ok)
        let reachable = try check(unreachable, .jiraReachable)
        #expect(!reachable.ok)
        #expect(reachable.blocksStart)
        #expect(reachable.fix == "Check the network or the VPN")
    }

    @Test func test_keychainAccessRefusedIsNotAMissingToken() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let refused = await (try makeDoctor(fixture, jira: nil, token: { throw KeychainError.unexpected(-128) })).run()
        let token = try check(refused, .jiraToken)
        #expect(!token.ok)
        #expect(token.blocksStart)
        #expect(token.detail == "Keychain access was refused or failed (status -128)")
        #expect(token.fix == "Allow TicketPilot in the Keychain prompt, then choose Check again")
        let missing = await (try makeDoctor(fixture, jira: nil, token: { throw KeychainError.notFound })).run()
        #expect(try check(missing, .jiraToken).detail == "No Jira token in the Keychain")
    }

    @Test func test_needsTokenWhenMissingOrRefusedButNotWhenKeychainFailed() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let missing = await (try makeDoctor(fixture, jira: nil, token: { throw KeychainError.notFound })).run()
        let refusedByJira = await (try makeDoctor(fixture, jira: FakeJira(.unauthorized))).run()
        let keychainFailed = await (try makeDoctor(fixture, jira: nil, token: { throw KeychainError.unexpected(-128) })).run()
        let healthy = await (try makeDoctor(fixture)).run()
        #expect(try check(missing, .jiraToken).needsToken)
        #expect(try check(refusedByJira, .jiraToken).needsToken)
        #expect(try !check(keychainFailed, .jiraToken).needsToken)
        #expect(try !check(healthy, .jiraToken).needsToken)
    }

    @Test func test_httpErrorPointsAtTheSite() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let http = await (try makeDoctor(fixture, jira: FakeJira(.http(status: 404)))).run()
        let site = try check(http, .jiraReachable)
        #expect(!site.ok)
        #expect(site.blocksStart)
        #expect(site.detail == "Jira answered unexpectedly")
        #expect(site.fix == "Check jira.site in the config (HTTP 404)")
        let invalid = await (try makeDoctor(fixture, jira: FakeJira(.invalidResponse))).run()
        #expect(try check(invalid, .jiraReachable).fix == "Check jira.site in the config")
    }

    @Test func mcpNeedingAuthenticationIsAWarning() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let output = "atlassian: https://x/mcp (HTTP) - ✗ Needs authentication\nfigma: https://y - ✓ Connected\nother: z - ✗ Failed\n"
        let checks = await (try makeDoctor(fixture, runner: MCPRunner(output: output))).run()
        let mcp = try check(checks, .mcp)
        #expect(!mcp.ok)
        #expect(!mcp.blocksStart)
        #expect(mcp.detail.contains("atlassian"))
        #expect(!mcp.detail.contains("figma"))
        #expect(!checks.allSatisfy { $0.ok })
        #expect(checks.canStart(repo: "ios"))
    }

    @Test func mcpNotConfiguredIsOk() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let checks = await (try makeDoctor(fixture, runner: MCPRunner(output: "other: z - ✓ Connected\n"))).run()
        let mcp = try check(checks, .mcp)
        #expect(mcp.ok)
        #expect(mcp.detail == "not configured")
    }

    @Test func mcpListFailureIsAWarning() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let failing = MCPRunner(output: "", status: 1)
        let throwing = MCPRunner()
        throwing.result = .failure(TokenError())
        for runner in [failing, throwing] {
            let checks = await (try makeDoctor(fixture, runner: runner)).run()
            let mcp = try check(checks, .mcp)
            #expect(!mcp.ok)
            #expect(!mcp.blocksStart)
            #expect(mcp.detail == "could not list the MCP servers")
        }
    }

    @Test func missingRepoPathBlocksOnlyThatRepo() async throws {
        let fixture = try makeFixture(existingRepos: false)
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let checks = await (try makeDoctor(fixture)).run()
        let repos = try check(checks, .repoPaths)
        #expect(!repos.ok)
        #expect(!repos.blocksStart)
        #expect(repos.blockedRepos == ["ios"])
        #expect(!checks.canStart(repo: "ios"))
        #expect(checks.canStart(repo: "web"))
    }

    @Test func lowDiskIsAWarning() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let checks = await (try makeDoctor(fixture, freeBytes: 2_000_000_000)).run()
        let disk = try check(checks, .diskSpace)
        #expect(!disk.ok)
        #expect(!disk.blocksStart)
        #expect(checks.canStart(repo: "ios"))
        #expect(!checks.allSatisfy { $0.ok })
    }

    @Test func unknownDiskSpaceIsOk() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let checks = await (try makeDoctor(fixture, freeBytes: nil)).run()
        let disk = try check(checks, .diskSpace)
        #expect(disk.ok)
        #expect(disk.detail == "unknown")
    }

    @Test func test_startBlockerFollowsTheRoute() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let repo = try makeConfig(fixture).repos[0]
        let missingRepo = HealthCheck(id: .repoPaths, ok: false, detail: "missing", blockedRepos: ["ios"])
        let noClaude = HealthCheck(id: .claudeCLI, ok: false, detail: "none", blocksStart: true)
        let disk = HealthCheck(id: .diskSpace, ok: false, detail: "low")

        #expect([disk, missingRepo].startBlocker(for: .direct(repo)) == missingRepo)
        #expect([disk, missingRepo].startBlocker(for: .pick([])) == nil)
        #expect([disk, noClaude].startBlocker(for: .pick([])) == noClaude)
        #expect([disk].startBlocker(repo: "ios") == nil)
    }

    @Test func test_everyCheckHasItsOwnTitle() {
        let titles = HealthCheck.Kind.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
        #expect(!titles.contains(""))
    }
}
