import Foundation
import Testing
@testable import TicketPilotCore

struct RepoMatcherTests {
    private let repos: [RepoConfig] = [
        makeRepo("ios", MatchRules(titlePrefixes: ["[iOS]"], labels: ["ios"])),
        makeRepo("android", MatchRules(titlePrefixes: ["[AND]"], labels: ["android"])),
        makeRepo("web", MatchRules(components: ["web"])),
    ]

    private static func makeRepo(_ name: String, _ match: MatchRules) -> RepoConfig {
        let json = """
        {"name": "\(name)", "path": "/tmp/\(name)", "main_branch": "main", "review": "none"}
        """
        var repo = try! JSONDecoder().decode(RepoConfig.self, from: Data(json.utf8))
        repo.match = match
        return repo
    }

    private func issue(
        _ summary: String, labels: [String] = [], components: [String] = []
    ) -> JiraIssue {
        JiraIssue(
            key: "ABC-1", summary: summary, statusName: "To Start", statusCategory: .toDo,
            labels: labels, components: components
        )
    }

    private func run(_ key: String, _ repo: String, status: Run.Status) -> Run {
        Run(
            id: "\(key)--\(repo)", key: key, repo: repo, repoPath: "/tmp/\(repo)", worktree: nil,
            branch: nil, sessionID: nil, session: nil, step: 1, stepName: "plan", status: status,
            waiting: nil, history: [], updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test func test_titlePrefixMatchesCaseInsensitively() {
        let names = RepoMatcher.repos(for: issue("[ios] Show distance"), in: repos).map(\.name)
        #expect(names == ["ios"])
    }

    @Test func test_labelOrComponentMatches() {
        #expect(RepoMatcher.repos(for: issue("Fix", labels: ["Android"]), in: repos).map(\.name) == ["android"])
        #expect(RepoMatcher.repos(for: issue("Fix", components: ["Web"]), in: repos).map(\.name) == ["web"])
    }

    @Test func test_twoPrefixesGiveTwoRepos() {
        let names = RepoMatcher.repos(for: issue("[iOS][AND] Same feature"), in: repos).map(\.name)
        #expect(names == ["ios", "android"])
    }

    @Test func test_noRuleGivesNoRepo() {
        #expect(RepoMatcher.repos(for: issue("Something else"), in: repos).isEmpty)
    }

    @Test func test_choicesListMatchedFirstThenOthers() {
        let choices = RepoMatcher.choices(for: issue("Fix", components: ["web"]), repos: repos, runs: [])
        #expect(choices.map(\.repo.name) == ["web", "ios", "android"])
        #expect(choices.map(\.matched) == [true, false, false])
        #expect(choices.map(\.id) == ["web", "ios", "android"])
    }

    @Test func test_existingRunTurnsIntoResume() {
        let runs = [
            run("ABC-1", "ios", status: .running),
            run("ABC-2", "android", status: .running),
        ]
        let choices = RepoMatcher.choices(for: issue("[iOS][AND] Same"), repos: repos, runs: runs)
        #expect(choices.first { $0.repo.name == "ios" }?.existingRunID == "ABC-1--ios")
        #expect(choices.first { $0.repo.name == "android" }?.existingRunID == nil)
    }

    @Test func test_doneRunAlsoCountsAsExisting() {
        let choices = RepoMatcher.choices(
            for: issue("[iOS] Done"), repos: repos, runs: [run("ABC-1", "ios", status: .done)]
        )
        #expect(choices.first?.existingRunID == "ABC-1--ios")
    }

    @Test func test_singleMatchWithoutRunStartsDirectly() {
        let choices = RepoMatcher.choices(for: issue("[iOS] Fix"), repos: repos, runs: [])
        #expect(StartRoute.make(choices: choices) == .direct(repos[0]))
    }

    @Test func test_otherwiseTheChoiceWindowOpens() {
        let two = RepoMatcher.choices(for: issue("[iOS][AND] Same"), repos: repos, runs: [])
        #expect(StartRoute.make(choices: two) == .pick(two))
        let none = RepoMatcher.choices(for: issue("Nothing"), repos: repos, runs: [])
        #expect(StartRoute.make(choices: none) == .pick(none))
        let withRun = RepoMatcher.choices(
            for: issue("[iOS] Fix"), repos: repos, runs: [run("ABC-1", "ios", status: .waiting)]
        )
        #expect(StartRoute.make(choices: withRun) == .pick(withRun))
    }

    @Test func test_initialSelectionTicksMatchedReposThatCanStart() {
        let choices = RepoMatcher.choices(for: issue("[iOS][AND] Same"), repos: repos, runs: [])
        #expect(StartRoute.initialSelection(choices, health: []) == ["ios", "android"])
        let missingIOS = [HealthCheck(id: .repoPaths, ok: false, detail: "x", blockedRepos: ["ios"])]
        #expect(StartRoute.initialSelection(choices, health: missingIOS) == ["android"])
    }
}
