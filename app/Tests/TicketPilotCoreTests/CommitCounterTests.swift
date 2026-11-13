import Foundation
import Testing
@testable import TicketPilotCore

@Suite(.timeLimit(.minutes(1))) struct CommitCounterTests {
    /// Answers each git command from a table, by its arguments after `-C <worktree>`.
    final class ScriptedGit: ProcessRunning, @unchecked Sendable {
        var answers: [[String]: ProcessResult]
        private(set) var calls: [[String]] = []

        init(_ answers: [[String]: ProcessResult]) {
            self.answers = answers
        }

        func run(_ executable: String, _ arguments: [String], currentDirectory: URL?) throws -> ProcessResult {
            calls.append(arguments)
            return answers[arguments] ?? ProcessResult(status: 128, output: "", error: "unexpected")
        }
    }

    static func ok(_ output: String) -> ProcessResult { ProcessResult(status: 0, output: output, error: "") }

    static let range = ["-C", "/wt", "rev-list", "--count", "--cherry-pick", "--right-only", "--no-merges"]

    @Test func test_countsTheWorktreeCommitsTheMainBranchDoesNotHaveByContent() {
        let git = ScriptedGit([Self.range + ["origin/main...HEAD"]: Self.ok("3\n")])
        #expect(CommitCounter(runner: git).count(worktree: "/wt", mainBranch: "main") == 3)
        #expect(git.calls == [Self.range + ["origin/main...HEAD"]])
    }

    @Test func test_anyGitFailureMeansUnknown() {
        let failing = ScriptedGit([:])
        #expect(CommitCounter(runner: failing).count(worktree: "/wt", mainBranch: "main") == nil)
        let garbage = ScriptedGit([Self.range + ["origin/main...HEAD"]: Self.ok("lots\n")])
        #expect(CommitCounter(runner: garbage).count(worktree: "/wt", mainBranch: "main") == nil)
    }

    @Test func test_mainHeadReadsOriginMainWithoutFetching() {
        let revParse = ["-C", "/wt", "rev-parse", "--verify", "--quiet", "origin/main^{commit}"]
        let git = ScriptedGit([revParse: Self.ok("abc123\n")])
        #expect(CommitCounter(runner: git).mainHead(worktree: "/wt", mainBranch: "main") == "abc123")
        #expect(git.calls == [revParse])
    }

    @Test func test_countsOnARealRepository() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tp-commits-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let origin = root.appendingPathComponent("origin")
        let clone = root.appendingPathComponent("clone")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        func git(_ arguments: [String], in directory: URL) throws {
            let result = try SystemProcessRunner().run(
                "/usr/bin/git",
                ["-c", "user.name=Test", "-c", "user.email=test@example.com"] + arguments,
                currentDirectory: directory
            )
            try #require(result.status == 0, "git \(arguments) failed: \(result.error)")
        }
        // Commits that change a file of their own, so that each has its own content.
        func commit(_ name: String, in directory: URL) throws {
            try name.write(to: directory.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
            try git(["add", "\(name).txt"], in: directory)
            try git(["commit", "-q", "-m", name], in: directory)
        }
        try git(["init", "-q", "-b", "main"], in: origin)
        try commit("initial", in: origin)
        try git(["clone", "-q", origin.path, clone.path], in: root)
        try git(["checkout", "-q", "-b", "feature"], in: clone)
        try commit("one", in: clone)
        try commit("two", in: clone)
        // The main branch moving on with other work changes nothing.
        try commit("elsewhere", in: origin)
        try git(["fetch", "-q"], in: clone)
        let counter = CommitCounter(runner: SystemProcessRunner())
        #expect(counter.count(worktree: clone.path, mainBranch: "main") == 2)
        #expect(counter.count(worktree: clone.path, mainBranch: "missing") == nil)

        // "one" merged under another hash, as a Gerrit submit does: only "two" is left to review.
        try commit("one", in: origin)
        try git(["fetch", "-q"], in: clone)
        #expect(counter.count(worktree: clone.path, mainBranch: "main") == 1)

        // A new branch checked out in the worktree is the one counted, not the run's first branch.
        try git(["checkout", "-q", "-b", "follow-up", "origin/main"], in: clone)
        try commit("three", in: clone)
        #expect(counter.count(worktree: clone.path, mainBranch: "main") == 1)
    }
}
