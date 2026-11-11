import Foundation
import Testing
@testable import TicketPilotCore

@Suite struct SetupProblemTests {
    static let claude = HealthCheck(id: .claudeCLI, ok: false, detail: "Claude Code not found", fix: "Install", blocksStart: true)
    static let plugin = HealthCheck(id: .plugin, ok: false, detail: "not installed", fix: "claude plugin install x", blocksStart: true)
    static let noToken = HealthCheck(id: .jiraToken, ok: false, detail: "No Jira token", fix: "security …", blocksStart: true, needsToken: true)
    static let keychain = HealthCheck(id: .jiraToken, ok: false, detail: "Keychain refused", fix: "Allow TicketPilot", blocksStart: true)
    static let unreachable = HealthCheck(id: .jiraReachable, ok: false, detail: "Jira is unreachable", fix: "Check the network", blocksStart: true)
    static let repos = HealthCheck(id: .repoPaths, ok: false, detail: "Path not found for: ios, web", blockedRepos: ["ios", "web"])
    static let mcp = HealthCheck(id: .mcp, ok: false, detail: "Not connected: figma")
    static let disk = HealthCheck(id: .diskSpace, ok: false, detail: "Only 2.0 GB free")
    static let fine = HealthCheck(id: .jiraReachable, ok: true, detail: "https://jira")

    @Test func test_claudeMissingComesFirstAndOpensTheDocs() {
        let all = [Self.disk, Self.repos, Self.unreachable, Self.noToken, Self.plugin, Self.claude]
        #expect(SetupProblem.first(in: all) == SetupProblem(
            title: "Install Claude Code…",
            headline: "Claude Code isn't installed yet",
            action: .openURL(URL(string: "https://docs.claude.com/claude-code")!)
        ))
    }

    @Test func test_pluginMissingCopiesTheInstallCommand() {
        let problem = SetupProblem.first(in: [Self.noToken, Self.plugin])
        #expect(problem == SetupProblem(
            title: "Install the ticket-pilot plugin…",
            headline: "The ticket-pilot plugin isn't installed yet",
            action: .copyFix(Self.plugin)
        ))
    }

    @Test func test_missingTokenConnectsJira() {
        let problem = SetupProblem.first(in: [Self.unreachable, Self.noToken])
        #expect(problem == SetupProblem(title: "Connect Jira…", headline: "Jira isn't connected yet", action: .setJiraToken))
    }

    @Test func test_refusedKeychainExplainsItsFix() {
        let problem = SetupProblem.first(in: [Self.unreachable, Self.keychain])
        #expect(problem == SetupProblem(
            title: "Allow Keychain access…",
            headline: "The Jira token can't be read",
            action: .explain(AlertText(title: "Keychain access", message: "Keychain refused\n\nAllow TicketPilot"))
        ))
    }

    @Test func test_unreachableJiraChecksAgain() {
        let problem = SetupProblem.first(in: [Self.repos, Self.unreachable])
        #expect(problem == SetupProblem(
            title: "Jira unreachable — check the network",
            headline: "Jira can't be reached right now",
            action: .checkAgain
        ))
        // A failed poll after a good check reads the same.
        #expect(SetupProblem.first(in: [Self.fine], jiraFailing: true) == problem)
        // Not before the checks are in: a missing token must not read as unreachable meanwhile.
        #expect(SetupProblem.first(in: [], jiraFailing: true) == nil)
    }

    @Test func test_missingRepoNamesItAndExplainsTheFix() {
        let problem = SetupProblem.first(in: [Self.disk, Self.repos])
        #expect(problem == SetupProblem(
            title: "Repository not found: ios, web…",
            headline: "Some repositories weren't found",
            action: .explain(AlertText(
                title: "Repository not found",
                message: "Path not found for: ios, web\n\nCorrect the repo path in your config, then choose Check again."
            ))
        ))
    }

    @Test func test_configErrorComesBeforeEverything() {
        let problem = SetupProblem.first(in: [Self.claude], configError: "not found at /c.json")
        #expect(problem == SetupProblem(
            title: "Fix the config…",
            headline: "The config needs a fix",
            action: .explain(AlertText(title: "Config", message: "not found at /c.json"))
        ))
    }

    @Test func test_oneMissingRepoReadsInTheSingular() {
        let one = HealthCheck(id: .repoPaths, ok: false, detail: "Path not found for: ios", blockedRepos: ["ios"])
        #expect(SetupProblem.first(in: [one])?.headline == "A repository wasn't found")
    }

    @Test func test_warningsAndPassingChecksAreNoProblem() {
        #expect(SetupProblem.first(in: [Self.mcp, Self.disk, Self.fine]) == nil)
        #expect(SetupProblem.first(in: []) == nil)
    }
}
