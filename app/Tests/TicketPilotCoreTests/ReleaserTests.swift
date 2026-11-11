import Foundation
import Testing
@testable import TicketPilotCore

@Suite(.timeLimit(.minutes(1))) struct ReleaserTests {
    struct Fixture {
        var root: URL
        var repo: URL
        var worktree: URL
        var runsDirectory: URL
        var run: Run

        var runFile: URL { runsDirectory.appendingPathComponent("\(run.id).json") }
        var fileManager: FileManager { .default }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func git(_ arguments: [String], in directory: URL? = nil) throws -> ProcessResult {
            let result = try SystemProcessRunner().run(
                "/usr/bin/git",
                ["-c", "user.name=Test", "-c", "user.email=test@example.com"] + arguments,
                currentDirectory: directory ?? repo
            )
            try #require(result.status == 0, "git \(arguments) failed: \(result.error)")
            return result
        }

        func branches() throws -> String {
            try git(["branch", "--list", "feature"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        let repo = root.appendingPathComponent("My Repos").appendingPathComponent("ios")
        let worktree = root.appendingPathComponent("wt")
        let runs = root.appendingPathComponent("runs")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        let run = Run(
            id: "ABC-1-ios", key: "ABC-1", repo: "ios", repoPath: repo.path,
            worktree: worktree.path, branch: "feature", sessionID: nil, session: nil,
            step: 1, stepName: "x", status: .done, waiting: nil, history: [], updatedAt: Date()
        )
        let fixture = Fixture(root: root, repo: repo, worktree: worktree, runsDirectory: runs, run: run)
        try fixture.git(["init", "-q", "-b", "main"])
        try fixture.git(["commit", "-q", "--allow-empty", "-m", "initial"])
        try fixture.git(["worktree", "add", "-q", "-b", "feature", worktree.path])
        try Data("{}".utf8).write(to: fixture.runFile)
        return fixture
    }

    @Test func test_planListsExactlyWhatWillBeDeleted() throws {
        let f = try makeFixture()
        defer { f.cleanUp() }
        let plan = ReleasePlan.make(run: f.run, runsDirectory: f.runsDirectory)
        #expect(plan.lines == [
            "Worktree: \(f.worktree.path)",
            "Local branch: feature",
            "Run state: \(f.runFile.path)",
        ])
        var bare = f.run
        bare.worktree = nil
        bare.branch = nil
        #expect(ReleasePlan.make(run: bare, runsDirectory: f.runsDirectory).lines == [
            "Run state: \(f.runFile.path)",
        ])
        var noWorktree = f.run
        noWorktree.worktree = nil
        #expect(ReleasePlan.make(run: noWorktree, runsDirectory: f.runsDirectory).lines == [
            "Local branch: feature",
            "Run state: \(f.runFile.path)",
        ])
    }

    @Test func test_releasesWorktreeBranchAndRunFile() throws {
        let f = try makeFixture()
        defer { f.cleanUp() }
        let plan = ReleasePlan.make(run: f.run, runsDirectory: f.runsDirectory)
        try Releaser(runner: SystemProcessRunner()).release(plan)
        #expect(!f.fileManager.fileExists(atPath: f.worktree.path))
        #expect(try f.branches().isEmpty)
        #expect(!f.fileManager.fileExists(atPath: f.runFile.path))
    }

    @Test func test_dirtyWorktreeIsKept() throws {
        let f = try makeFixture()
        defer { f.cleanUp() }
        try Data("work".utf8).write(to: f.worktree.appendingPathComponent("wip.txt"))
        let plan = ReleasePlan.make(run: f.run, runsDirectory: f.runsDirectory)
        do {
            try Releaser(runner: SystemProcessRunner()).release(plan)
            Issue.record("expected failure")
        } catch {
            guard case .worktreeNotRemoved(let message) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(message.contains("contains modified or untracked files"))
            #expect(message == message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        #expect(f.fileManager.fileExists(atPath: f.worktree.path))
        #expect(!(try f.branches().isEmpty))
        #expect(f.fileManager.fileExists(atPath: f.runFile.path))
    }

    @Test func test_unmergedBranchIsKept() throws {
        let f = try makeFixture()
        defer { f.cleanUp() }
        try f.git(["commit", "-q", "--allow-empty", "-m", "own work"], in: f.worktree)
        let plan = ReleasePlan.make(run: f.run, runsDirectory: f.runsDirectory)
        let command = "git -C '\(f.repo.path)' branch -D 'feature'"
        do {
            try Releaser(runner: SystemProcessRunner()).release(plan)
            Issue.record("expected failure")
        } catch {
            guard case .branchNotDeleted(let message, let shown) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(!message.isEmpty)
            #expect(shown == command)
        }
        #expect(!f.fileManager.fileExists(atPath: f.worktree.path))
        #expect(!(try f.branches().isEmpty))
        #expect(f.fileManager.fileExists(atPath: f.runFile.path))
    }

    @Test func test_releaseCanBeRetriedAfterUnmergedBranch() throws {
        let f = try makeFixture()
        defer { f.cleanUp() }
        try f.git(["commit", "-q", "--allow-empty", "-m", "own work"], in: f.worktree)
        let plan = ReleasePlan.make(run: f.run, runsDirectory: f.runsDirectory)
        let releaser = Releaser(runner: SystemProcessRunner())
        do {
            try releaser.release(plan)
            Issue.record("expected failure")
        } catch {
            guard case .branchNotDeleted = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }
        // The worktree is gone; the branch is then reset so it has no commit of its own.
        try f.git(["branch", "-f", "feature", "HEAD"])
        try releaser.release(plan)
        #expect(try f.branches().isEmpty)
        #expect(!f.fileManager.fileExists(atPath: f.runFile.path))
    }

    @Test func test_releaseCanBeRetriedAfterTheUserDeletedTheBranch() throws {
        let f = try makeFixture()
        defer { f.cleanUp() }
        try f.git(["commit", "-q", "--allow-empty", "-m", "own work"], in: f.worktree)
        let plan = ReleasePlan.make(run: f.run, runsDirectory: f.runsDirectory, mainBranch: "main")
        let releaser = Releaser(runner: SystemProcessRunner())
        #expect(throws: ReleaseError.self) { try releaser.release(plan) }
        // What the alert tells the user to run.
        try f.git(["branch", "-D", "feature"])
        try releaser.release(plan)
        #expect(try f.branches().isEmpty)
        #expect(!f.fileManager.fileExists(atPath: f.runFile.path))
    }

    @Test(arguments: ["main", "master", "develop", "checked-out"])
    func test_neverDeletesTheMainOrCheckedOutBranch(branch: String) throws {
        let f = try makeFixture()
        defer { f.cleanUp() }
        try f.git(["branch", "develop"])
        if branch == "checked-out" {
            try f.git(["checkout", "-q", "-b", "checked-out"])
        }
        if branch == "master" {
            try f.git(["branch", "master"])
        }
        var run = f.run
        run.branch = branch
        let plan = ReleasePlan.make(run: run, runsDirectory: f.runsDirectory, mainBranch: "develop")
        do {
            try Releaser(runner: SystemProcessRunner()).release(plan)
            Issue.record("expected failure")
        } catch {
            #expect(error == .protectedBranch(branch: branch))
            #expect(error.alertText.title == "The branch was kept")
        }
        let listed = try f.git(["branch", "--list", branch]).output
        #expect(!listed.isEmpty)
        // Refused before anything is deleted.
        #expect(f.fileManager.fileExists(atPath: f.worktree.path))
        #expect(f.fileManager.fileExists(atPath: f.runFile.path))
    }

    @Test func test_releasableOnlyForDoneTickets() {
        func run(_ id: String, _ key: String) -> Run {
            Run(
                id: id, key: key, repo: "ios", repoPath: "/r", worktree: nil, branch: nil,
                sessionID: nil, session: nil, step: 1, stepName: "x", status: .running,
                waiting: nil, history: [], updatedAt: Date()
            )
        }
        let runs = [run("ABC-1-ios", "ABC-1"), run("ABC-2-ios", "ABC-2"), run("ABC-3-ios", "ABC-3")]
        let ids = Releasable.runIDs(runs: runs, categories: [
            "ABC-1": .done, "ABC-2": .inProgress,
        ])
        #expect(ids == ["ABC-1-ios"])
    }

    @Test func test_diskUsageReadsKilobytes() throws {
        let f = try makeFixture()
        defer { f.cleanUp() }
        let size = diskUsage(of: f.worktree.path, runner: SystemProcessRunner())
        #expect((size ?? 0) > 0)
        #expect(diskUsage(of: f.root.appendingPathComponent("missing").path, runner: SystemProcessRunner()) == nil)
    }

    @Test func test_alertTextGivesTheCommandForAnUnmergedBranch() {
        let branch = ReleaseError.branchNotDeleted(message: "not fully merged", command: "git -C '/r' branch -D 'f'")
        #expect(branch.alertText.title == "The branch was kept")
        #expect(branch.alertText.message.hasPrefix("not fully merged"))
        #expect(branch.alertText.message.hasSuffix("git -C '/r' branch -D 'f'"))
        let worktree = ReleaseError.worktreeNotRemoved(message: "contains modified files")
        #expect(worktree.alertText == AlertText(title: "The worktree was kept", message: "contains modified files"))
    }
}
