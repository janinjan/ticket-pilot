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

    @Test func test_countsTheBranchCommitsSinceTheMergeBaseWithTheMainBranch() {
        let git = ScriptedGit([
            ["-C", "/wt", "merge-base", "HEAD", "origin/main"]: Self.ok("abc123\n"),
            ["-C", "/wt", "rev-list", "--count", "abc123..feature"]: Self.ok("3\n"),
        ])
        #expect(CommitCounter(runner: git).count(worktree: "/wt", branch: "feature", mainBranch: "main") == 3)
    }

    @Test func test_withoutABranchCountsUpToHEAD() {
        let git = ScriptedGit([
            ["-C", "/wt", "merge-base", "HEAD", "origin/develop"]: Self.ok("abc\n"),
            ["-C", "/wt", "rev-list", "--count", "abc..HEAD"]: Self.ok("1\n"),
        ])
        #expect(CommitCounter(runner: git).count(worktree: "/wt", branch: nil, mainBranch: "develop") == 1)
    }

    @Test func test_anyGitFailureMeansUnknown() {
        let noBase = ScriptedGit([:])
        #expect(CommitCounter(runner: noBase).count(worktree: "/wt", branch: "feature", mainBranch: "main") == nil)
        #expect(noBase.calls.count == 1)
        let garbage = ScriptedGit([
            ["-C", "/wt", "merge-base", "HEAD", "origin/main"]: Self.ok("abc\n"),
            ["-C", "/wt", "rev-list", "--count", "abc..feature"]: Self.ok("lots\n"),
        ])
        #expect(CommitCounter(runner: garbage).count(worktree: "/wt", branch: "feature", mainBranch: "main") == nil)
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
        try git(["init", "-q", "-b", "main"], in: origin)
        try git(["commit", "-q", "--allow-empty", "-m", "initial"], in: origin)
        try git(["clone", "-q", origin.path, clone.path], in: root)
        try git(["checkout", "-q", "-b", "feature"], in: clone)
        try git(["commit", "-q", "--allow-empty", "-m", "one"], in: clone)
        try git(["commit", "-q", "--allow-empty", "-m", "two"], in: clone)
        // The main branch moving on afterwards changes nothing.
        try git(["commit", "-q", "--allow-empty", "-m", "elsewhere"], in: origin)
        try git(["fetch", "-q"], in: clone)
        let counter = CommitCounter(runner: SystemProcessRunner())
        #expect(counter.count(worktree: clone.path, branch: "feature", mainBranch: "main") == 2)
        #expect(counter.count(worktree: clone.path, branch: "feature", mainBranch: "missing") == nil)
    }
}
