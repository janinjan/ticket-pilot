import Foundation
import Testing
@testable import TicketPilotCore

@Suite(.timeLimit(.minutes(1))) struct PanelStatusTests {
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

    static func make(_ runs: [Run], problem: SetupProblem? = nil, signingIn: Bool = false) -> PanelStatus? {
        PanelStatus.make(runs: runs, setupProblem: problem, signingIn: signingIn)
    }

    @Test func test_nothingToSayMeansNoStatusAtAll() {
        // The cards start right under the header: no "All quiet", no report or progress headline.
        #expect(Self.make([]) == nil)
        #expect(Self.make([Self.run("c", .done), Self.run("d", .running), Self.run("u", .unknown)]) == nil)
    }

    @Test func test_ticketsWaitingAreOneLine() {
        let runs = [
            Self.run("a", .waiting, key: "ABC-1"),
            Self.run("b", .waiting, key: "ABC-2", repo: "web"),
            Self.run("d", .running),
        ]
        #expect(Self.make(runs) == PanelStatus(headline: "2 tickets need you", subtitle: nil, needsSetup: false))
        // Two repos of one ticket are one ticket.
        let oneTicket = [Self.run("a", .waiting), Self.run("b", .waiting, repo: "web")]
        #expect(Self.make(oneTicket)?.headline == "1 ticket needs you")
    }

    @Test func test_aSetupProblemComesFirstSayingAlmostThereAndWhy() {
        // The panel shows it as a banner holding the button, at the top.
        let runs = [Self.run("a", .waiting), Self.run("c", .done)]
        #expect(Self.make(runs, problem: Self.connectJira) == PanelStatus(
            headline: "Almost there! 👋", subtitle: "Connect Jira to see your tickets here.", needsSetup: true
        ))
    }

    @Test func test_anEmptyListSaysNoTicketIsAssigned() {
        #expect(PanelStatus.emptyListText(hasRuns: false, todoCount: 0) == "No tickets assigned to you")
        // Not before Jira answered, and not with anything to list.
        #expect(PanelStatus.emptyListText(hasRuns: false, todoCount: nil) == nil)
        #expect(PanelStatus.emptyListText(hasRuns: true, todoCount: 0) == nil)
        #expect(PanelStatus.emptyListText(hasRuns: false, todoCount: 2) == nil)
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
        let status = Self.make([Self.run("a", .waiting)], problem: Self.connectJira, signingIn: true)
        #expect(status == PanelStatus(
            headline: "Waiting for Atlassian sign-in…", subtitle: "Finish signing in in your browser.", needsSetup: true
        ))
    }
}
