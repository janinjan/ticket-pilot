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

    /// A run stopped before its worktree (the ticket was already done) has only its run file to remove:
    /// the action says so instead of "Remove worktree".
    @Test func test_theActionIsNamedAfterWhatGoes() throws {
        let f = try makeFixture()
        defer { f.cleanUp() }
        #expect(Releasable.actionTitle(for: f.run) == "Remove worktree…")
        #expect(ReleasePlan.make(run: f.run, runsDirectory: f.runsDirectory).question == "Remove the worktree of ABC-1 · ios?")
        var noWorktree = f.run
        noWorktree.worktree = nil
        noWorktree.branch = nil
        #expect(Releasable.actionTitle(for: noWorktree) == "Remove from the list…")
        #expect(ReleasePlan.make(run: noWorktree, runsDirectory: f.runsDirectory).question == "Remove ABC-1 · ios from the list?")
    }

    /// A removal that kept the branch has deleted the worktree already: what is left is said, not the
    /// worktree again.
    @Test func test_aWorktreeAlreadyGoneIsNoLongerOffered() throws {
        let f = try makeFixture()
        defer { f.cleanUp() }
        try FileManager.default.removeItem(at: f.worktree)
        #expect(!Releasable.worktreeExists(f.run))
        #expect(Releasable.actionTitle(for: f.run) == "Remove from the list…")
        let plan = ReleasePlan.make(run: f.run, runsDirectory: f.runsDirectory)
        #expect(plan.question == "Remove ABC-1 · ios from the list?")
        #expect(plan.lines == ["Local branch: feature", "Run state: \(f.runFile.path)"])
        try Releaser(runner: SystemProcessRunner()).release(plan)
        #expect(try f.branches().isEmpty)
        #expect(!f.fileManager.fileExists(atPath: f.runFile.path))
    }

    @Test func test_anUnmergedBranchIsDeletedOnceTheUserChoseTo() throws {
        let f = try makeFixture()
        defer { f.cleanUp() }
        try f.commitFile("work.txt", in: f.worktree)
        let plan = ReleasePlan.make(run: f.run, runsDirectory: f.runsDirectory, mainBranch: "main")
        let releaser = Releaser(runner: SystemProcessRunner())
        #expect(throws: ReleaseError.self) { try releaser.release(plan) }
        try releaser.release(plan, forceBranches: true)
        #expect(try f.branches().isEmpty)
        #expect(!f.fileManager.fileExists(atPath: f.runFile.path))
    }

    // MARK: - Up for review on Gerrit

    /// Runs git for real; answers `ssh` (the Gerrit query) with `gerrit`, and records its arguments.
    final class GerritRunner: ProcessRunning, @unchecked Sendable {
        var answer: (String) -> String
        private(set) var queries: [[String]] = []

        init(answer: @escaping (String) -> String) {
            self.answer = answer
        }

        func run(_ executable: String, _ arguments: [String], currentDirectory: URL?) throws -> ProcessResult {
            guard executable == "/usr/bin/ssh" else {
                return try SystemProcessRunner().run(executable, arguments, currentDirectory: currentDirectory)
            }
            queries.append(arguments)
            let changeID = String(arguments.last?.dropFirst("change:".count) ?? "")
            return ProcessResult(status: 0, output: answer(changeID), error: "")
        }
    }

    private static let changeID = "I069290230d6d737876c3c78f83e9be77b4bb3a7e"

    /// A fixture whose `origin` is a Gerrit server, the main branch on it, and one commit of the branch
    /// with a Change-Id; returns that commit.
    private func makeGerritFixture() throws -> (Fixture, commit: String) {
        let f = try makeFixture()
        try f.git(["remote", "add", "origin", "ssh://me@review.example.com:29418/ios/app"])
        try f.git(["update-ref", "refs/remotes/origin/main", "main"])
        try Data("work".utf8).write(to: f.worktree.appendingPathComponent("work.txt"))
        try f.git(["add", "work.txt"], in: f.worktree)
        try f.git(["commit", "-q", "-m", "work\n\nChange-Id: \(Self.changeID)"], in: f.worktree)
        let commit = try f.git(["rev-parse", "HEAD"], in: f.worktree).output.trimmingCharacters(in: .whitespacesAndNewlines)
        return (f, commit)
    }

    private static func queryOutput(revisions: [String]) -> String {
        let patchSets = revisions.enumerated().map { #"{"number":\#($0.offset + 1),"revision":"\#($0.element)"}"# }
        return #"{"project":"ios/app","patchSets":[\#(patchSets.joined(separator: ","))]}"# + "\n"
            + #"{"type":"stats","rowCount":1}"# + "\n"
    }

    @Test func test_aBranchUpForReviewOnGerritIsDeleted() throws {
        let (f, commit) = try makeGerritFixture()
        defer { f.cleanUp() }
        let runner = GerritRunner { _ in Self.queryOutput(revisions: ["0000", commit]) }
        let plan = ReleasePlan.make(run: f.run, runsDirectory: f.runsDirectory, mainBranch: "main")
        try Releaser(runner: runner).release(plan)
        #expect(try f.branches().isEmpty)
        #expect(!f.fileManager.fileExists(atPath: f.runFile.path))
        let query = try #require(runner.queries.first)
        #expect(query.contains("BatchMode=yes"))
        #expect(Array(query.suffix(8)) == [
            "-p", "29418", "me@review.example.com", "gerrit", "query", "--format=JSON", "--patch-sets",
            "change:\(Self.changeID)",
        ])
    }

    @Test func test_aBranchWhoseCommitGerritDoesNotHaveIsKept() throws {
        let (f, _) = try makeGerritFixture()
        defer { f.cleanUp() }
        // Amended after the push: the change has an older patch set only.
        let runner = GerritRunner { _ in Self.queryOutput(revisions: ["0000"]) }
        let plan = ReleasePlan.make(run: f.run, runsDirectory: f.runsDirectory, mainBranch: "main")
        #expect(throws: ReleaseError.self) { try Releaser(runner: runner).release(plan) }
        #expect(!(try f.branches().isEmpty))
        #expect(f.fileManager.fileExists(atPath: f.runFile.path))
    }

    @Test func test_aBranchIsKeptWhenGerritCannotBeAsked() throws {
        let (f, _) = try makeGerritFixture()
        defer { f.cleanUp() }
        let runner = GerritRunner { _ in "" }
        let plan = ReleasePlan.make(run: f.run, runsDirectory: f.runsDirectory, mainBranch: "main")
        #expect(throws: ReleaseError.self) { try Releaser(runner: runner).release(plan) }
        #expect(!(try f.branches().isEmpty))
    }

    @Test func test_aCommitWithoutChangeIDKeepsTheBranch() throws {
        let (f, _) = try makeGerritFixture()
        defer { f.cleanUp() }
        try f.commitFile("more.txt", in: f.worktree)
        let runner = GerritRunner { _ in Self.queryOutput(revisions: []) }
        let plan = ReleasePlan.make(run: f.run, runsDirectory: f.runsDirectory, mainBranch: "main")
        #expect(throws: ReleaseError.self) { try Releaser(runner: runner).release(plan) }
        #expect(!(try f.branches().isEmpty))
    }

    @Test func test_gerritServerOnlyForAnSSHGerritRemote() {
        #expect(GerritServer(remote: "ssh://me@review.example.com:29418/ios/app\n")
            == GerritServer(destination: "me@review.example.com", port: 29418))
        #expect(GerritServer(remote: "ssh://gerrit.example.com/ios/app")
            == GerritServer(destination: "gerrit.example.com", port: nil))
        #expect(GerritServer(remote: "https://review.example.com/a/ios/app") == nil)
        #expect(GerritServer(remote: "git@github.com:me/app.git") == nil)
        #expect(GerritServer(remote: "ssh://git@github.com/me/app.git") == nil)
    }

    @Test func test_onlyAChangeIDIsSentToGerrit() {
        #expect(GerritServer.isChangeID(Self.changeID))
        #expect(!GerritServer.isChangeID("I0692; rm -rf ~"))
        #expect(!GerritServer.isChangeID(""))
        let runner = GerritRunner { _ in Self.queryOutput(revisions: ["abc"]) }
        let server = GerritServer(destination: "review.example.com", port: 29418)
        #expect(server.revisions(ofChange: "I1 OR project:x", runner: runner).isEmpty)
        #expect(runner.queries.isEmpty)
    }

    @Test func test_releasesWorktreeBranchRunFileAndReport() throws {
        let f = try makeFixture()
        defer { f.cleanUp() }
        let report = RunReport.file(runID: f.run.id, runsDirectory: f.runsDirectory)
        try Data("# Report".utf8).write(to: report)
        let shots = f.runsDirectory.appendingPathComponent("\(f.run.id).screenshots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: shots.appendingPathComponent("case-1.png"))
        let plan = ReleasePlan.make(run: f.run, runsDirectory: f.runsDirectory)
        try Releaser(runner: SystemProcessRunner()).release(plan)
        #expect(!f.fileManager.fileExists(atPath: shots.path))
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

    /// `git worktree remove` that fails half way (files in use, here a folder it can't empty) still forgets
    /// the worktree: the folder left behind is no longer one, and the retry must finish the job.
    @Test func test_releaseCanBeRetriedAfterGitLeftPartOfTheWorktree() throws {
        let f = try makeFixture()
        defer {
            _ = try? SystemProcessRunner().run("/bin/chmod", ["-R", "u+w", f.root.path], currentDirectory: nil)
            f.cleanUp()
        }
        try Data("build/\n".utf8).write(to: f.repo.appendingPathComponent(".git/info/exclude"))
        let locked = f.worktree.appendingPathComponent("build/locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: locked.appendingPathComponent("output"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        let plan = ReleasePlan.make(run: f.run, runsDirectory: f.runsDirectory)
        let releaser = Releaser(runner: SystemProcessRunner())
        do {
            try releaser.release(plan)
            Issue.record("expected failure")
        } catch {
            guard case let .worktreeNotRemoved(message) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(message.hasSuffix(ReleaseError.retryHint))
        }
        // Git already forgot it, the folder is still there.
        #expect(f.fileManager.fileExists(atPath: f.worktree.path))
        #expect(!(try f.git(["worktree", "list"]).output.contains(f.worktree.path)))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        try releaser.release(plan)
        #expect(!f.fileManager.fileExists(atPath: f.worktree.path))
        #expect(try f.branches().isEmpty)
        #expect(!f.fileManager.fileExists(atPath: f.runFile.path))
    }

    /// Git may delete the leftover's `.git` before the file it could not delete: the failed release
    /// remembers the folder, so the retry still finishes.
    @Test func test_retryFinishesEvenWhenGitDeletedTheLeftoversLink() throws {
        let f = try makeFixture()
        defer {
            _ = try? SystemProcessRunner().run("/bin/chmod", ["-R", "u+w", f.root.path], currentDirectory: nil)
            f.cleanUp()
        }
        try Data("build/\n".utf8).write(to: f.repo.appendingPathComponent(".git/info/exclude"))
        let locked = f.worktree.appendingPathComponent("build/locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: locked.appendingPathComponent("output"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        let plan = ReleasePlan.make(run: f.run, runsDirectory: f.runsDirectory)
        let releaser = Releaser(runner: SystemProcessRunner())
        #expect(throws: ReleaseError.self) { try releaser.release(plan) }
        try? FileManager.default.removeItem(at: f.worktree.appendingPathComponent(".git"))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        try releaser.release(plan)
        #expect(!f.fileManager.fileExists(atPath: f.worktree.path))
        #expect(!f.fileManager.fileExists(atPath: f.runFile.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: f.runsDirectory.path)
        #expect(leftovers.isEmpty)
    }

    @Test func test_aFolderThatIsNoWorktreeLeftoverIsKept() throws {
        let f = try makeFixture()
        defer { f.cleanUp() }
        try f.git(["worktree", "remove", "--", f.worktree.path])
        try FileManager.default.createDirectory(at: f.worktree, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: f.worktree.appendingPathComponent("notes.txt"))
        let plan = ReleasePlan.make(run: f.run, runsDirectory: f.runsDirectory)
        #expect(throws: ReleaseError.self) { try Releaser(runner: SystemProcessRunner()).release(plan) }
        #expect(f.fileManager.fileExists(atPath: f.worktree.appendingPathComponent("notes.txt").path))
        #expect(f.fileManager.fileExists(atPath: f.runFile.path))
    }

    @Test func test_unmergedBranchIsKept() throws {
        let f = try makeFixture()
        defer { f.cleanUp() }
        try f.git(["commit", "-q", "--allow-empty", "-m", "own work"], in: f.worktree)
        let plan = ReleasePlan.make(run: f.run, runsDirectory: f.runsDirectory)
        do {
            try Releaser(runner: SystemProcessRunner()).release(plan)
            Issue.record("expected failure")
        } catch {
            guard case .branchNotDeleted(let branch, let message) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(branch == "feature")
            #expect(!message.isEmpty)
            // Git's hints name `branch -D`: the alert's button replaces them.
            #expect(!message.contains("hint:"))
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

    @Test func test_runWithoutWorktreeAndWithItsSessionClosedCanBeRemoved() {
        // Waiting for the go, its tab closed: the ticket can go back to Start.
        let run = Run(
            id: "ABC-1-ios", key: "ABC-1", repo: "ios", repoPath: "/r", worktree: nil, branch: nil,
            sessionID: "s1", session: .init(state: "ended", lastNotification: nil, notifiedAt: nil),
            step: 1, stepName: "understand", status: .waiting, waiting: nil, history: [], updatedAt: Date()
        )
        #expect(Releasable.runIDs(runs: [run], categories: [:]) == ["ABC-1-ios"])
        // The menu and the confirmation say where the ticket goes: back to its Start button.
        #expect(Releasable.actionTitle(for: run) == "Back to Start…")
        let plan = ReleasePlan.make(run: run, runsDirectory: URL(fileURLWithPath: "/runs"))
        #expect(plan.question == "Put ABC-1 · ios back to Start?")
        #expect(plan.outcome == "The run is forgotten; ABC-1 is listed again with its Start button.")
        #expect(plan.confirmTitle == "Back to Start")
    }

    @Test func test_runWithALiveSessionOrAWorktreeIsNotRemovableBeforeItsEnd() throws {
        let f = try makeFixture()
        defer { f.cleanUp() }
        func run(_ id: String, worktree: String?, state: String) -> Run {
            Run(
                id: id, key: id, repo: "ios", repoPath: "/r", worktree: worktree, branch: nil,
                sessionID: "s1", session: .init(state: state, lastNotification: nil, notifiedAt: nil),
                step: 1, stepName: "understand", status: .waiting, waiting: nil, history: [], updatedAt: Date()
            )
        }
        let runs = [
            run("live", worktree: nil, state: "running"),
            run("asking", worktree: nil, state: "waiting"),
            run("coded", worktree: f.worktree.path, state: "ended"),
        ]
        #expect(Releasable.runIDs(runs: runs, categories: [:]).isEmpty)
    }

    @Test func test_diskUsageReadsKilobytes() throws {
        let f = try makeFixture()
        defer { f.cleanUp() }
        let size = diskUsage(of: f.worktree.path, runner: SystemProcessRunner())
        #expect((size ?? 0) > 0)
        #expect(diskUsage(of: f.root.appendingPathComponent("missing").path, runner: SystemProcessRunner()) == nil)
    }

    @Test func test_alertTextTellsWhyAnUnmergedBranchIsKept() {
        let branch = ReleaseError.branchNotDeleted(branch: "f", message: "not fully merged")
        #expect(branch.alertText.title == "The branch f was kept")
        #expect(branch.alertText.message.hasPrefix("The worktree is removed."))
        #expect(branch.alertText.message.contains("neither in the main branch nor up for review"))
        #expect(branch.alertText.message.hasSuffix("not fully merged"))
        let worktree = ReleaseError.worktreeNotRemoved(message: "contains modified files")
        #expect(worktree.alertText == AlertText(title: "The worktree was kept", message: "contains modified files"))
    }
}
