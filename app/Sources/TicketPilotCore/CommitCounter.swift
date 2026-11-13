import Foundation

/// Counts the commits a finished run made: those checked out in its worktree that the repo's main branch
/// does not have yet, compared by content, so that a commit merged under another hash (a Gerrit submit, a
/// rebase or a cherry-pick) is no longer counted.
public struct CommitCounter: Sendable {
    private static let git = "/usr/bin/git"

    public var runner: ProcessRunning

    public init(runner: ProcessRunning) {
        self.runner = runner
    }

    /// `git rev-list --count --cherry-pick --right-only --no-merges origin/<mainBranch>...HEAD` in the
    /// worktree. Nil when git fails or answers something else than a number.
    public func count(worktree: String, mainBranch: String) -> Int? {
        let range = "origin/\(mainBranch)...HEAD"
        guard let count = output(["-C", worktree, "rev-list", "--count", "--cherry-pick", "--right-only", "--no-merges", range])
        else { return nil }
        return Int(count)
    }

    /// The commit `origin/<mainBranch>` points to in the worktree: a local read, without fetching. Nil when
    /// git fails.
    public func mainHead(worktree: String, mainBranch: String) -> String? {
        output(["-C", worktree, "rev-parse", "--verify", "--quiet", "origin/\(mainBranch)^{commit}"])
    }

    private func output(_ arguments: [String]) -> String? {
        guard let result = try? runner.run(Self.git, arguments, currentDirectory: nil), result.status == 0 else {
            return nil
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
