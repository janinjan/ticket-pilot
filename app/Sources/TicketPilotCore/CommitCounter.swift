import Foundation

/// Counts the commits a finished run made: those of its branch since it left the repo's main branch.
public struct CommitCounter: Sendable {
    private static let git = "/usr/bin/git"

    public var runner: ProcessRunning

    public init(runner: ProcessRunning) {
        self.runner = runner
    }

    /// `git rev-list --count <base>..<branch>` in the worktree, the base being
    /// `git merge-base HEAD origin/<mainBranch>`; HEAD without a branch. Nil when git fails or answers
    /// something else than a number.
    public func count(worktree: String, branch: String?, mainBranch: String) -> Int? {
        guard let base = output(["-C", worktree, "merge-base", "HEAD", "origin/\(mainBranch)"]), !base.isEmpty,
              let count = output(["-C", worktree, "rev-list", "--count", "\(base)..\(branch ?? "HEAD")"])
        else { return nil }
        return Int(count)
    }

    private func output(_ arguments: [String]) -> String? {
        guard let result = try? runner.run(Self.git, arguments, currentDirectory: nil), result.status == 0 else {
            return nil
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
