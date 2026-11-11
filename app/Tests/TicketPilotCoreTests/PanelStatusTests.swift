import Foundation
import Testing
@testable import TicketPilotCore

@Suite struct PanelStatusTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let connectJira = SetupProblem(
        title: "Connect Jira…", explanation: "Connect Jira to see your tickets here.", action: .setJiraToken
    )

    static func run(
        _ id: String, _ status: Run.Status, key: String = "ABC-1", repo: String = "ios", updatedMinutesAgo: Int = 0,
        title: String? = nil
    ) -> Run {
        var run = Run(
            id: id, key: key, repo: repo, repoPath: "/r", worktree: nil, branch: nil, sessionID: nil,
            session: nil, step: 6, stepName: "verify", status: status,
            waiting: status == .waiting ? Run.Waiting(kind: "question", text: "?", since: now) : nil,
            history: [], updatedAt: now.addingTimeInterval(-Double(updatedMinutesAgo) * 60)
        )
        run.title = title
        return run
    }

    static func make(
        _ runs: [Run], acknowledged: Set<String> = [], problem: SetupProblem? = nil, todoCount: Int? = 0,
        summaries: [String: String] = [:]
    ) -> PanelStatus {
        PanelStatus.make(
            runs: runs, acknowledgedDone: acknowledged, setupProblem: problem, todoCount: todoCount, summaries: summaries
        )
    }

    @Test func test_quietInvitesACoffeeAndSaysHowManyTicketsAreLeft() {
        #expect(Self.make([]) == PanelStatus(
            headline: "All quiet. Enjoy your coffee ☕", subtitle: "No ticket assigned", needsSetup: false
        ))
        #expect(Self.make([], todoCount: 1).subtitle == "1 ticket to do")
        #expect(Self.make([], todoCount: 3).subtitle == "3 tickets to do")
        // Before the first Jira answer, nothing is claimed about the tickets.
        #expect(Self.make([], todoCount: nil).subtitle == nil)
    }

    @Test func test_ticketsWaitingComeAfterTheSetupAndNameTheLatestOne() {
        let runs = [
            Self.run("a", .waiting, key: "ABC-1", updatedMinutesAgo: 30),
            Self.run("b", .waiting, key: "ABC-2", repo: "web", updatedMinutesAgo: 2, title: "Pick the wording"),
            Self.run("c", .done),
            Self.run("d", .running),
        ]
        #expect(Self.make(runs, problem: Self.connectJira).needsSetup)
        let status = Self.make(runs)
        #expect(status == PanelStatus(headline: "2 tickets need you", subtitle: "Pick the wording", needsSetup: false))
        // Two repos of one ticket are one ticket.
        let oneTicket = [Self.run("a", .waiting), Self.run("b", .waiting, repo: "web")]
        #expect(Self.make(oneTicket).headline == "1 ticket needs you")
    }

    @Test func test_aSetupProblemComesFirstSayingAlmostThereAndWhy() {
        // The panel shows it as a banner holding the button, at the top.
        let runs = [Self.run("a", .waiting), Self.run("c", .done), Self.run("d", .running)]
        #expect(Self.make(runs, problem: Self.connectJira) == PanelStatus(
            headline: "Almost there! 👋", subtitle: "Connect Jira to see your tickets here.", needsSetup: true
        ))
    }

    @Test func test_reportsNotOpenedYetComeBeforeRunsInProgress() {
        let runs = [
            Self.run("c", .done, key: "ABC-3", updatedMinutesAgo: 10),
            Self.run("e", .done, key: "ABC-4", updatedMinutesAgo: 1),
            Self.run("d", .running, key: "ABC-5"),
        ]
        #expect(Self.make(runs, summaries: ["ABC-4": "Show the distance"]) == PanelStatus(
            headline: "2 reports are ready 🎉", subtitle: "Show the distance", needsSetup: false
        ))
        #expect(Self.make(runs, acknowledged: ["e"]).headline == "Your report is ready 🎉")
        #expect(Self.make(runs, acknowledged: ["e"]).subtitle == "ABC-3")
    }

    @Test func test_workingNamesTheStepOfTheLatestRun() {
        let runs = [Self.run("d", .running, key: "ABC-5", updatedMinutesAgo: 5), Self.run("u", .unknown, key: "ABC-6")]
        #expect(Self.make(runs) == PanelStatus(
            headline: "Working on it…", subtitle: "Verifying · ABC-6", needsSetup: false
        ))
        // Every report opened and nothing at work: quiet again.
        let quiet = Self.make([Self.run("c", .done)], acknowledged: ["c"])
        #expect(quiet.headline == "All quiet. Enjoy your coffee ☕")
    }

    @Test func test_theTitleComesFromTheRunThenJiraThenTheKey() {
        let run = Self.run("a", .done, key: "ABC-1", title: "From the run")
        #expect(RunTitle.of(run, summaries: ["ABC-1": "From Jira"]) == "From the run")
        #expect(RunTitle.of(Self.run("a", .done, key: "ABC-1"), summaries: ["ABC-1": "From Jira"]) == "From Jira")
        #expect(RunTitle.of(Self.run("a", .done, key: "ABC-1", title: "  "), summaries: [:]) == "ABC-1")
    }

    @Test func test_repoNamesReadAsTheirPlatform() {
        #expect(RepoName.display("ios") == "iOS")
        #expect(RepoName.display("Android") == "Android")
        #expect(RepoName.display("web") == "Web")
        #expect(RepoName.display("backend-api") == "backend-api")
    }

    @Test func test_waitingForTheSignInComesFirst() {
        let status = PanelStatus.make(
            runs: [Self.run("a", .waiting)], acknowledgedDone: [], setupProblem: Self.connectJira, todoCount: nil,
            signingIn: true
        )
        #expect(status == PanelStatus(
            headline: "Waiting for Atlassian sign-in…", subtitle: "Finish signing in in your browser.", needsSetup: true
        ))
    }
}
