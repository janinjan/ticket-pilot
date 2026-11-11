import Foundation
import Testing
@testable import TicketPilotCore

@Suite struct SetupProblemTests {
    static let claude = HealthCheck(id: .claudeCLI, ok: false, detail: "Claude Code not found", fix: "Install", blocksStart: true)
    static let plugin = HealthCheck(
        id: .plugin, ok: false, detail: "not installed", fix: "claude plugin install x", blocksStart: true, pluginState: .missing
    )
    static let outdated = HealthCheck(
        id: .plugin, ok: false, detail: "installed 0.1.2 · bundled 0.1.3", pluginState: .outdated(installed: "0.1.2", bundled: "0.1.3")
    )
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
            explanation: "Install Claude Code to start a ticket.",
            action: .openURL(URL(string: "https://docs.claude.com/claude-code")!)
        ))
    }

    @Test func test_pluginMissingOffersToInstallIt() {
        let problem = SetupProblem.first(in: [Self.noToken, Self.plugin])
        #expect(problem == SetupProblem(
            title: "Install the Claude Code plugin…",
            explanation: "Install the Claude Code plugin to start a ticket.",
            action: .installPlugin(.missing)
        ))
    }

    @Test func test_pluginOutdatedOffersToUpdateItAfterJira() {
        let state = PluginState.outdated(installed: "0.1.2", bundled: "0.1.3")
        #expect(SetupProblem.first(in: [Self.outdated, Self.disk]) == SetupProblem(
            title: "Update the Claude Code plugin (0.1.2 → 0.1.3)…",
            explanation: "A newer Claude Code plugin is ready to install.",
            action: .installPlugin(state)
        ))
        // An update can wait: what blocks a run comes first.
        #expect(SetupProblem.first(in: [Self.outdated, Self.noToken])?.action == .setJiraToken)
        #expect(SetupProblem.first(in: [Self.outdated, Self.repos])?.title == "Repository not found: ios, web…")
    }

    @Test func test_missingTokenConnectsJira() {
        let problem = SetupProblem.first(in: [Self.unreachable, Self.noToken])
        #expect(problem == SetupProblem(title: "Connect Jira…", explanation: "Connect Jira to see your tickets here.", action: .setJiraToken))
    }

    @Test func test_refusedKeychainExplainsItsFix() {
        let problem = SetupProblem.first(in: [Self.unreachable, Self.keychain])
        #expect(problem == SetupProblem(
            title: "Allow Keychain access…",
            explanation: "Allow Keychain access so TicketPilot can read your Jira token.",
            action: .explain(AlertText(title: "Keychain access", message: "Keychain refused\n\nAllow TicketPilot"))
        ))
    }

    @Test func test_unreachableJiraChecksAgain() {
        let problem = SetupProblem.first(in: [Self.repos, Self.unreachable])
        #expect(problem == SetupProblem(
            title: "Check again",
            explanation: "Jira can't be reached right now. Check your network.",
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
            explanation: "Some repositories weren't found. Check their paths in your config.",
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
            explanation: "Fix your config to get started.",
            action: .explain(AlertText(title: "Config", message: "not found at /c.json"))
        ))
    }

    @Test func test_oneMissingRepoReadsInTheSingular() {
        let one = HealthCheck(id: .repoPaths, ok: false, detail: "Path not found for: ios", blockedRepos: ["ios"])
        #expect(SetupProblem.first(in: [one])?.explanation == "A repository wasn't found. Check its path in your config.")
    }

    @Test func test_theButtonEndsWithAnArrowInsteadOfAnEllipsis() {
        #expect(SetupProblem(title: "Connect Jira…", explanation: "", action: .setJiraToken).buttonTitle == "Connect Jira →")
        #expect(SetupProblem(title: "Check again", explanation: "", action: .checkAgain).buttonTitle == "Check again →")
    }

    @Test func test_warningsAndPassingChecksAreNoProblem() {
        #expect(SetupProblem.first(in: [Self.mcp, Self.disk, Self.fine]) == nil)
        #expect(SetupProblem.first(in: []) == nil)
    }

    // MARK: - Atlassian MCP

    static let notSignedIn = HealthCheck(
        id: .jiraSignIn, ok: false, detail: "Not connected to Atlassian", blocksStart: true, needsToken: true
    )

    @Test func test_notSignedInConnectsJiraThroughAtlassian() {
        let problem = SetupProblem.first(in: [Self.unreachable, Self.notSignedIn])
        #expect(problem == SetupProblem(
            title: "Connect Jira…", explanation: "Connect Jira to see your tickets here.", action: .connectAtlassian
        ))
    }

    @Test func test_refusedByAtlassianExplainsWithTheServerMessage() {
        let refused = HealthCheck(
            id: .jiraSignIn, ok: false, detail: "Your admin blocked this app", fix: "Ask your admin",
            blocksStart: true, refusedByServer: true
        )
        #expect(SetupProblem.first(in: [refused]) == SetupProblem(
            title: "See why Jira refused…",
            explanation: "Atlassian refused the connection to Jira.",
            action: .explain(AlertText(title: "Atlassian refused the connection", message: "Your admin blocked this app\n\nAsk your admin"))
        ))
    }

    @Test func test_keychainRefusedForTheSignInExplainsItsFix() {
        let keychain = HealthCheck(id: .jiraSignIn, ok: false, detail: "Keychain refused", fix: "Allow TicketPilot", blocksStart: true)
        #expect(SetupProblem.first(in: [keychain]) == SetupProblem(
            title: "Allow Keychain access…",
            explanation: "Allow Keychain access so TicketPilot can read your Atlassian sign-in.",
            action: .explain(AlertText(title: "Keychain access", message: "Keychain refused\n\nAllow TicketPilot"))
        ))
    }
}
