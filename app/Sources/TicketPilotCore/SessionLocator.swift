import Foundation

/// A terminal surface (a tab or split) reported by a scriptable terminal app.
public struct TerminalSurface: Equatable, Sendable {
    public var id: String
    public var name: String
    public var workingDirectory: String

    public init(id: String, name: String, workingDirectory: String) {
        self.id = id
        self.name = name
        self.workingDirectory = workingDirectory
    }
}

/// Finds the terminal surface a run's Claude Code session most likely lives in.
public enum SessionLocator {
    private static let spinnerGlyphs: [Character] = ["✳", "✻", "◐", "◑", "◒", "◓"]

    /// The folders a session can be in, most specific first: where its last hook ran, its worktree, its repo.
    public static func candidateFolders(for run: Run) -> [String] {
        var folders: [String] = []
        for path in [run.session?.cwd, run.worktree, run.repoPath] {
            guard let path, !path.isEmpty else { continue }
            let folder = standardized(path)
            if !folders.contains(folder) { folders.append(folder) }
        }
        return folders
    }

    /// The terminal in the earliest folder; within a folder, one titled like a Claude Code session, else the first.
    /// With `claudeOnly`, a terminal not titled like a Claude Code session is never picked (a plain shell
    /// in the folder is not the session).
    public static func pickTerminal(
        _ terminals: [TerminalSurface], folders: [String], claudeOnly: Bool = false
    ) -> String? {
        for folder in folders.map(standardized) {
            let inFolder = terminals.filter { standardized($0.workingDirectory) == folder }
            let best = inFolder.first(where: { looksLikeClaude($0.name) }) ?? (claudeOnly ? nil : inFolder.first)
            if let best {
                return best.id
            }
        }
        return nil
    }

    static func looksLikeClaude(_ title: String) -> Bool {
        if let first = title.first, spinnerGlyphs.contains(first) { return true }
        // "claude" as a whole word: not inside a name such as "claude-tools" or "~/claude.d".
        return title.range(
            of: #"(?<![\p{L}\p{N}_./-])claude(?![\p{L}\p{N}_./-])"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func standardized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}
