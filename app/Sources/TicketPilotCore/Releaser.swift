import Foundation

/// Exactly what releasing a run will delete, for the confirmation dialog.
public struct ReleasePlan: Equatable, Sendable {
    public var runID: String
    public var repoPath: String
    public var worktree: String?
    /// The run's branch, then the branch checked out in its worktree when it is another one.
    public var branches: [String]
    public var runFile: URL
    public var mainBranch: String?
    public var lines: [String]

    /// `checkedOutBranch` is the branch checked out in the run's worktree (`Releaser.checkedOutBranch`), when
    /// the work went on there after the run.
    public static func make(
        run: Run, runsDirectory: URL, mainBranch: String? = nil, checkedOutBranch: String? = nil
    ) -> ReleasePlan {
        let runFile = runsDirectory.appendingPathComponent("\(run.id).json")
        var branches: [String] = []
        for branch in [run.branch, checkedOutBranch] {
            guard let branch, !branch.isEmpty, !branches.contains(branch) else { continue }
            branches.append(branch)
        }
        var lines: [String] = []
        if let worktree = run.worktree { lines.append("Worktree: \(worktree)") }
        lines += branches.map { "Local branch: \($0)" }
        lines.append("Run state: \(runFile.path)")
        return ReleasePlan(
            runID: run.id, repoPath: run.repoPath, worktree: run.worktree, branches: branches,
            runFile: runFile, mainBranch: mainBranch, lines: lines
        )
    }
}

public enum Releasable {
    /// Runs that are finished, or whose ticket is Done in Jira (a run left before its end).
    public static func runIDs(runs: [Run], categories: [String: JiraIssue.StatusCategory]) -> Set<String> {
        Set(runs.filter { $0.status == .done || categories[$0.key] == .done }.map(\.id))
    }
}

public enum ReleaseError: Error, Equatable {
    case worktreeNotRemoved(message: String)
    /// `command` is the forced deletion, shown so the user can run it themselves.
    case branchNotDeleted(message: String, command: String)
    case runFileNotRemoved(message: String)
    /// The branch is the repo's main branch or the one checked out in the main repo: nothing is deleted.
    case protectedBranch(branch: String)
}

/// Title and text of an alert.
public struct AlertText: Equatable, Sendable {
    public var title: String
    public var message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

extension ReleaseError {
    /// What the failure alert says: why nothing more was deleted, and for an unmerged
    /// branch the command to run yourself.
    public var alertText: AlertText {
        switch self {
        case let .worktreeNotRemoved(message):
            AlertText(title: "The worktree was kept", message: message)
        case let .branchNotDeleted(message, command):
            AlertText(
                title: "The branch was kept",
                message: message + "\n\nTo delete it anyway, run:\n" + command
            )
        case let .runFileNotRemoved(message):
            AlertText(title: "The run file was kept", message: message)
        case let .protectedBranch(branch):
            AlertText(
                title: "The branch was kept",
                message: "\(branch) is the main branch or the branch checked out in the repo: "
                    + "ticket-pilot never deletes it. Nothing was deleted."
            )
        }
    }
}

/// Removes a worktree, its branches and the run file, in that order, stopping at the first failure.
/// Never loses work: git refuses a dirty worktree (`worktree remove`), and a branch is deleted only when
/// `origin/<main branch>` has all its commits by content (merged under other hashes, as Gerrit does), or
/// when git itself sees it merged (`branch -d`). Refuses up front, deleting nothing, when a branch is the
/// main branch or the one checked out in the repo.
public struct Releaser: Sendable {
    private static let git = "/usr/bin/git"
    private static let mainBranchNames: Set<String> = ["main", "master"]
    private let runner: ProcessRunning

    public init(runner: ProcessRunning) {
        self.runner = runner
    }

    public func release(_ plan: ReleasePlan) throws(ReleaseError) {
        if let branch = plan.branches.first(where: { isProtected($0, plan: plan) }) {
            throw .protectedBranch(branch: branch)
        }
        if let worktree = plan.worktree {
            // A worktree already gone (earlier partial release, or deleted by hand) only needs its
            // registration pruned, so a retry can move on to the branch.
            let arguments = FileManager.default.fileExists(atPath: worktree)
                ? ["-C", plan.repoPath, "worktree", "remove", "--", worktree]
                : ["-C", plan.repoPath, "worktree", "prune"]
            let result = execute(arguments)
            guard result.status == 0 else { throw .worktreeNotRemoved(message: result.error) }
        }
        // A branch already deleted (with the `branch -D` the alert shows) only needs the run file removed.
        for branch in plan.branches where branchExists(branch, repoPath: plan.repoPath) {
            let delete = isMergedByContent(branch, plan: plan) ? "-D" : "-d"
            let result = execute(["-C", plan.repoPath, "branch", delete, "--", branch])
            guard result.status == 0 else {
                let command = "git -C \(SessionCommand.quote(plan.repoPath)) branch -D \(SessionCommand.quote(branch))"
                throw .branchNotDeleted(message: result.error, command: command)
            }
        }
        do {
            let report = plan.runFile.deletingPathExtension().appendingPathExtension("report.md")
            if FileManager.default.fileExists(atPath: report.path) {
                try FileManager.default.removeItem(at: report)
            }
            try FileManager.default.removeItem(at: plan.runFile)
        } catch {
            throw .runFileNotRemoved(message: error.localizedDescription)
        }
    }

    private func isProtected(_ branch: String, plan: ReleasePlan) -> Bool {
        if Self.mainBranchNames.contains(branch) || branch == plan.mainBranch { return true }
        let head = execute(["-C", plan.repoPath, "symbolic-ref", "--quiet", "--short", "HEAD"])
        return head.status == 0 && head.output.trimmingCharacters(in: .whitespacesAndNewlines) == branch
    }

    /// The branch checked out in `worktree`, nil when it is detached, gone or git fails.
    public func checkedOutBranch(worktree: String) -> String? {
        let result = execute(["-C", worktree, "branch", "--show-current"])
        let branch = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.status == 0 && !branch.isEmpty ? branch : nil
    }

    /// `origin/<main branch>` has every commit of `branch`, compared by content: nothing would be lost.
    private func isMergedByContent(_ branch: String, plan: ReleasePlan) -> Bool {
        guard let mainBranch = plan.mainBranch else { return false }
        let result = execute([
            "-C", plan.repoPath, "rev-list", "--count", "--cherry-pick", "--right-only", "--no-merges",
            "origin/\(mainBranch)...refs/heads/\(branch)",
        ])
        return result.status == 0 && result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "0"
    }

    /// Only a clean "no such ref" (status 1) counts as absent: any other failure goes on to
    /// `branch -d`, which reports it.
    private func branchExists(_ branch: String, repoPath: String) -> Bool {
        execute(["-C", repoPath, "rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"]).status != 1
    }

    private func execute(_ arguments: [String]) -> ProcessResult {
        do {
            var result = try runner.run(Self.git, arguments, currentDirectory: nil)
            result.error = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            return result
        } catch {
            return ProcessResult(status: -1, output: "", error: error.localizedDescription)
        }
    }
}

/// Size of a folder in bytes, or nil when it cannot be measured.
public func diskUsage(of path: String, runner: ProcessRunning) -> Int64? {
    guard let result = try? runner.run("/usr/bin/du", ["-sk", "--", path], currentDirectory: nil),
          result.status == 0,
          let first = result.output.split(whereSeparator: \.isWhitespace).first,
          let kilobytes = Int64(first)
    else { return nil }
    return kilobytes * 1024
}
