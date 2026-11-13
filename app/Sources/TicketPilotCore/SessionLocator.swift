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

    /// The folders a session can be in, most specific first: where its last hook ran, where it was started
    /// (the first `cwd` of its transcript: the folder its terminal tab reports, even after the session moved
    /// to another one), its worktree, its repo.
    public static func candidateFolders(
        for run: Run, projectsDirectory: URL = SessionCommand.defaultProjectsDirectory()
    ) -> [String] {
        let started = run.sessionID.flatMap {
            SessionCommand.transcriptDirectory(sessionID: $0, projectsDirectory: projectsDirectory)
        }
        var folders: [String] = []
        for path in [run.session?.cwd, started, run.worktree, run.repoPath] {
            guard let path, !path.isEmpty else { continue }
            let folder = standardized(path)
            if !folders.contains(folder) { folders.append(folder) }
        }
        return folders
    }

    /// First a terminal whose title names the run's `key` as a whole token (Claude Code titles its tab
    /// after the ticket, while the folder a tab reports may be the launcher's): one in the run's folders,
    /// else one titled like a Claude Code session, else (without `claudeOnly`) the first. Then the terminal
    /// in the earliest folder; within a folder, one titled like a Claude Code session, else the first.
    /// With `claudeOnly`, a terminal not titled like a Claude Code session is never picked (a plain shell
    /// in the folder is not the session).
    public static func pickTerminal(
        _ terminals: [TerminalSurface], key: String? = nil, folders: [String], claudeOnly: Bool = false
    ) -> String? {
        let folders = folders.map(standardized)
        if let key {
            let named = terminals.filter { names($0.name, key: key) }
            let claude = named.filter { looksLikeClaude($0.name) }
            let inFolder = claude.first { folders.contains(standardized($0.workingDirectory)) }
            if let best = inFolder ?? claude.first ?? (claudeOnly ? nil : named.first) {
                return best.id
            }
        }
        for folder in folders {
            let inFolder = terminals.filter { standardized($0.workingDirectory) == folder }
            let best = inFolder.first(where: { looksLikeClaude($0.name) }) ?? (claudeOnly ? nil : inFolder.first)
            if let best {
                return best.id
            }
        }
        return nil
    }

    /// `key` as a whole token, case-sensitive: "ABC-1" is not in "ABC-12" nor in "XABC-1".
    static func names(_ title: String, key: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        return title.range(of: #"(?<![\p{L}\p{N}_-])"# + escaped + #"(?![\p{L}\p{N}_])"#, options: .regularExpression) != nil
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
