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
    /// The confirmation's question, named after what goes: the worktree, or only the run's card.
    public var question: String

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
        // A worktree already deleted (by an earlier try, or by hand) is no longer named: only its
        // registration is pruned.
        let present = Releasable.worktreeExists(run)
        var lines: [String] = []
        if present, let worktree = run.worktree { lines.append("Worktree: \(worktree)") }
        lines += branches.map { "Local branch: \($0)" }
        lines.append("Run state: \(runFile.path)")
        let question = present
            ? "Remove the worktree of \(run.key) · \(run.repo)?"
            : "Remove \(run.key) · \(run.repo) from the list?"
        return ReleasePlan(
            runID: run.id, repoPath: run.repoPath, worktree: run.worktree, branches: branches,
            runFile: runFile, mainBranch: mainBranch, lines: lines, question: question
        )
    }
}

public enum Releasable {
    /// The card's menu item: "Remove worktree…", or "Remove from the list…" for a run whose worktree is
    /// gone or never was (stopped before step 2, for a ticket already done).
    public static func actionTitle(for run: Run) -> String {
        worktreeExists(run) ? "Remove worktree…" : "Remove from the list…"
    }

    /// The run's worktree folder is still on disk.
    public static func worktreeExists(_ run: Run) -> Bool {
        run.worktree.map { FileManager.default.fileExists(atPath: $0) } ?? false
    }

    /// Runs that are finished, or whose ticket is Done in Jira (a run left before its end).
    public static func runIDs(runs: [Run], categories: [String: JiraIssue.StatusCategory]) -> Set<String> {
        Set(runs.filter { $0.status == .done || categories[$0.key] == .done }.map(\.id))
    }
}

public enum ReleaseError: Error, Equatable {
    case worktreeNotRemoved(message: String)
    /// The branch has commits neither merged nor up for review; the alert offers to delete it anyway.
    case branchNotDeleted(branch: String, message: String)
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
    /// After a worktree only partly deleted: what to do so the next try ends it.
    static let retryHint = "\n\nSome files could not be deleted: an app (Xcode, a build) may still be using the "
        + "worktree. Quit it, then choose Remove worktree again."

    /// What the failure alert says: why nothing more was deleted. For an unmerged branch, the alert also
    /// offers "Delete Anyway" (`AppModel.release`).
    public var alertText: AlertText {
        switch self {
        case let .worktreeNotRemoved(message):
            AlertText(title: "The worktree was kept", message: message)
        case let .branchNotDeleted(branch, message):
            AlertText(
                title: "The branch \(branch) was kept",
                message: "The worktree is removed. The branch has commits that are neither in the main branch "
                    + "nor up for review: deleting it loses them.\n\n" + message
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
/// `origin/<main branch>` has all its commits by content (merged under other hashes, as Gerrit does), when
/// each commit not on `origin` is a patch set on the Gerrit server `origin` points to (up for review), or
/// when git itself sees it merged (`branch -d`); `forceBranches` deletes it anyway, once the user chose to.
/// Refuses up front, deleting nothing, when a branch is the main branch or the one checked out in the repo.
public struct Releaser: Sendable {
    private static let git = "/usr/bin/git"
    private static let mainBranchNames: Set<String> = ["main", "master"]
    private let runner: ProcessRunning

    public init(runner: ProcessRunning) {
        self.runner = runner
    }

    public func release(_ plan: ReleasePlan, forceBranches: Bool = false) throws(ReleaseError) {
        if let branch = plan.branches.first(where: { isProtected($0, plan: plan) }) {
            throw .protectedBranch(branch: branch)
        }
        if let worktree = plan.worktree {
            let prune = ["-C", plan.repoPath, "worktree", "prune"]
            let marker = Self.leftoverMarker(of: plan)
            let arguments: [String]
            if !FileManager.default.fileExists(atPath: worktree) {
                // Already gone (earlier release, or deleted by hand): only its registration to prune, so a
                // retry can move on to the branch.
                arguments = prune
            } else if isLeftover(worktree, repoPath: plan.repoPath) || Self.isMarkedLeftover(worktree, marker: marker) {
                // What a `worktree remove` that failed half way leaves: git forgot the worktree first, so it
                // no longer removes the folder; its clean check had passed, so only what it was deleting is left.
                do {
                    try FileManager.default.removeItem(atPath: worktree)
                } catch {
                    throw .worktreeNotRemoved(message: error.localizedDescription + ReleaseError.retryHint)
                }
                arguments = prune
            } else {
                arguments = ["-C", plan.repoPath, "worktree", "remove", "--", worktree]
            }
            let result = execute(arguments)
            guard result.status == 0 else {
                let partial = result.error.contains("failed to delete")
                if partial {
                    // Git checked the worktree and forgot it before failing: what is left is only what it was
                    // deleting. Remembered, since git may have deleted its `.git` link already.
                    try? Data(worktree.utf8).write(to: marker, options: .atomic)
                }
                throw .worktreeNotRemoved(message: result.error + (partial ? ReleaseError.retryHint : ""))
            }
            try? FileManager.default.removeItem(at: marker)
        }
        // A branch already deleted (with the `branch -D` the alert shows) only needs the run file removed.
        for branch in plan.branches where branchExists(branch, repoPath: plan.repoPath) {
            let safe = forceBranches || isMergedByContent(branch, plan: plan) || isUpForReview(branch, plan: plan)
            let result = execute(["-C", plan.repoPath, "branch", safe ? "-D" : "-d", "--", branch])
            guard result.status == 0 else {
                // Git's hints name `branch -D`: the alert offers it as a button.
                let message = result.error.split(whereSeparator: \.isNewline)
                    .filter { !$0.hasPrefix("hint:") }.joined(separator: "\n")
                throw .branchNotDeleted(branch: branch, message: message)
            }
        }
        do {
            let base = plan.runFile.deletingPathExtension()
            // The report and the screenshots of step 7, kept next to the run file.
            for companion in [base.appendingPathExtension("report.md"), base.appendingPathExtension("screenshots")]
            where FileManager.default.fileExists(atPath: companion.path) {
                try FileManager.default.removeItem(at: companion)
            }
            try FileManager.default.removeItem(at: plan.runFile)
        } catch {
            throw .runFileNotRemoved(message: error.localizedDescription)
        }
    }

    /// Next to the run file: the worktree a failed `worktree remove` left, once git had checked it.
    private static func leftoverMarker(of plan: ReleasePlan) -> URL {
        plan.runFile.deletingPathExtension().appendingPathExtension("leftover")
    }

    private static func isMarkedLeftover(_ worktree: String, marker: URL) -> Bool {
        (try? String(contentsOf: marker, encoding: .utf8)) == worktree
    }

    /// A folder git no longer knows as a worktree but that was one of this repo: its `.git` file still
    /// points to `<repo's git dir>/worktrees/<name>`, which is gone. Any other folder is left alone.
    private func isLeftover(_ worktree: String, repoPath: String) -> Bool {
        let link = URL(fileURLWithPath: worktree).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: link.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let content = try? String(contentsOf: link, encoding: .utf8),
              content.hasPrefix("gitdir: ")
        else { return false }
        let gitDir = URL(fileURLWithPath: String(content.dropFirst("gitdir: ".count))
            .trimmingCharacters(in: .whitespacesAndNewlines))
        let registrations = gitDir.deletingLastPathComponent()
        let common = execute(["-C", repoPath, "rev-parse", "--path-format=absolute", "--git-common-dir"])
        guard common.status == 0, registrations.lastPathComponent == "worktrees",
              !FileManager.default.fileExists(atPath: gitDir.path)
        else { return false }
        let repoGitDir = URL(fileURLWithPath: common.output.trimmingCharacters(in: .whitespacesAndNewlines))
        return registrations.deletingLastPathComponent().resolvingSymlinksInPath().path
            == repoGitDir.resolvingSymlinksInPath().path
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

    /// Each commit of `branch` that no `origin` branch has is a patch set on the Gerrit server `origin`
    /// points to: the changes keep the work. False when one is not, or when Gerrit can't be asked.
    private func isUpForReview(_ branch: String, plan: ReleasePlan) -> Bool {
        let remote = execute(["-C", plan.repoPath, "remote", "get-url", "origin"])
        guard remote.status == 0, let server = GerritServer(remote: remote.output) else { return false }
        let list = execute(["-C", plan.repoPath, "rev-list", "--no-merges", "refs/heads/\(branch)", "--not", "--remotes=origin"])
        let commits = list.output.split(whereSeparator: \.isNewline).map(String.init)
        guard list.status == 0, !commits.isEmpty else { return false }
        var revisions: [String: Set<String>] = [:]
        return commits.allSatisfy { commit in
            let trailer = execute(["-C", plan.repoPath, "log", "-1", "--format=%(trailers:key=Change-Id,valueonly)", commit])
            guard trailer.status == 0,
                  let changeID = trailer.output.split(whereSeparator: \.isNewline).last.map(String.init)
            else { return false }
            if revisions[changeID] == nil {
                revisions[changeID] = server.revisions(ofChange: changeID, runner: runner)
            }
            return revisions[changeID]?.contains(commit) == true
        }
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
