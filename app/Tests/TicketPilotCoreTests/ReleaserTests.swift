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

        func branches(_ pattern: String = "feature") throws -> String {
            try git(["branch", "--list", pattern]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// A commit that adds `name` with its own content, in `directory` (the repo by default).
        func commitFile(_ name: String, in directory: URL? = nil) throws {
            let folder = directory ?? repo
            try Data(name.utf8).write(to: folder.appendingPathComponent(name))
            try git(["add", name], in: folder)
            try git(["commit", "-q", "-m", name], in: folder)
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

    @Test func test_releasesWorktreeBranchRunFileAndReport() throws {
        let f = try makeFixture()
        defer { f.cleanUp() }
        let report = RunReport.file(runID: f.run.id, runsDirectory: f.runsDirectory)
        try Data("# Report".utf8).write(to: report)
        let plan = ReleasePlan.make(run: f.run, runsDirectory: f.runsDirectory)
        try Releaser(runner: SystemProcessRunner()).release(plan)
        #expect(!f.fileManager.fileExists(atPath: f.worktree.path))
        #expect(try f.branches().isEmpty)
        #expect(!f.fileManager.fileExists(atPath: f.runFile.path))
        #expect(!f.fileManager.fileExists(atPath: report.path))
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

    @Test func test_branchMergedUnderAnotherHashIsDeleted() throws {
        let f = try makeFixture()
        defer { f.cleanUp() }
        try f.commitFile("work.txt", in: f.worktree)
        // The same change lands on the main branch under another hash, as a Gerrit submit does.
        try f.commitFile("work.txt")
        try f.git(["update-ref", "refs/remotes/origin/main", "main"])
        let plan = ReleasePlan.make(run: f.run, runsDirectory: f.runsDirectory, mainBranch: "main")
        try Releaser(runner: SystemProcessRunner()).release(plan)
        #expect(try f.branches().isEmpty)
        #expect(!f.fileManager.fileExists(atPath: f.runFile.path))
    }

    @Test func test_branchWithWorkMissingFromTheMainBranchIsKept() throws {
        let f = try makeFixture()
        defer { f.cleanUp() }
        try f.commitFile("work.txt", in: f.worktree)
        try f.git(["update-ref", "refs/remotes/origin/main", "main"])
        let plan = ReleasePlan.make(run: f.run, runsDirectory: f.runsDirectory, mainBranch: "main")
        #expect(throws: ReleaseError.self) { try Releaser(runner: SystemProcessRunner()).release(plan) }
        #expect(!(try f.branches().isEmpty))
        #expect(f.fileManager.fileExists(atPath: f.runFile.path))
    }

    @Test func test_theBranchCheckedOutInTheWorktreeIsDeletedToo() throws {
        let f = try makeFixture()
        defer { f.cleanUp() }
        try f.git(["checkout", "-q", "-b", "follow-up"], in: f.worktree)
        let releaser = Releaser(runner: SystemProcessRunner())
        let checkedOut = releaser.checkedOutBranch(worktree: f.worktree.path)
        #expect(checkedOut == "follow-up")
        let plan = ReleasePlan.make(run: f.run, runsDirectory: f.runsDirectory, checkedOutBranch: checkedOut)
        #expect(plan.lines == [
            "Worktree: \(f.worktree.path)",
            "Local branch: feature",
            "Local branch: follow-up",
            "Run state: \(f.runFile.path)",
        ])
        try releaser.release(plan)
        #expect(try f.branches().isEmpty)
        #expect(try f.branches("follow-up").isEmpty)
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

    @Test func test_releasableForFinishedRunsAndDoneTickets() {
        func run(_ id: String, _ key: String, _ status: Run.Status = .running) -> Run {
            Run(
                id: id, key: key, repo: "ios", repoPath: "/r", worktree: nil, branch: nil,
                sessionID: nil, session: nil, step: 1, stepName: "x", status: status,
                waiting: nil, history: [], updatedAt: Date()
            )
        }
        let runs = [
            run("ABC-1-ios", "ABC-1"), run("ABC-2-ios", "ABC-2"), run("ABC-3-ios", "ABC-3"),
            run("ABC-4-ios", "ABC-4", .done),
        ]
        let ids = Releasable.runIDs(runs: runs, categories: [
            "ABC-1": .done, "ABC-2": .inProgress, "ABC-4": .inProgress,
        ])
        #expect(ids == ["ABC-1-ios", "ABC-4-ios"])
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
