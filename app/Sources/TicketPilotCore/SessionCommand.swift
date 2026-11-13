import Foundation

public enum SessionCommandError: Error, Equatable {
    case invalidKey(String)
    case invalidSessionID(String)
}

/// Builds the shell line that starts or resumes a Claude Code session.
public enum SessionCommand {
    // Mirrors `runs.KEY_PATTERN` and `hooks.SAFE_SESSION_ID`. Checked by hand so a trailing newline never passes.
    public static func start(
        key: String,
        repoPath: String,
        permissionMode: String?
    ) throws(SessionCommandError) -> String {
        guard isValidKey(key) else { throw .invalidKey(key) }
        var parts = ["cd \(quote(repoPath)) && claude"]
        if let permissionMode {
            parts.append("--permission-mode \(quote(permissionMode))")
        }
        parts.append(quote("/ticket-pilot:start \(key)"))
        return parts.joined(separator: " ")
    }

    public static func resume(sessionID: String, directory: String) throws(SessionCommandError) -> String {
        guard isValidSessionID(sessionID) else { throw .invalidSessionID(sessionID) }
        return "cd \(quote(directory)) && claude --resume \(quote(sessionID))"
    }

    /// Resumes the run's session from the folder Claude Code stored it under; a run without a session starts again.
    public static func resume(
        _ run: Run,
        permissionMode: String?,
        projectsDirectory: URL = defaultProjectsDirectory()
    ) throws(SessionCommandError) -> String {
        guard let sessionID = run.sessionID else {
            return try start(key: run.key, repoPath: run.repoPath, permissionMode: permissionMode)
        }
        return try resume(
            sessionID: sessionID,
            directory: resumeDirectory(for: run, projectsDirectory: projectsDirectory)
        )
    }

    /// Claude Code keeps a conversation under the folder it STARTED in, and `--resume` only finds it from
    /// there. In order: the `cwd` the plugin recorded; the `cwd` of the session's transcript; the worktree,
    /// else the repo. Any error reading the transcript falls back.
    public static func resumeDirectory(
        for run: Run,
        projectsDirectory: URL = defaultProjectsDirectory()
    ) -> String {
        if let cwd = run.session?.cwd, !cwd.isEmpty {
            return cwd
        }
        if let sessionID = run.sessionID,
           let cwd = transcriptDirectory(sessionID: sessionID, projectsDirectory: projectsDirectory) {
            return cwd
        }
        return run.worktree ?? run.repoPath
    }

    /// `$CLAUDE_CONFIG_DIR/projects`, else `~/.claude/projects`.
    public static func defaultProjectsDirectory() -> URL {
        if let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !config.isEmpty {
            return URL(fileURLWithPath: config).appendingPathComponent("projects")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    /// The session's transcript, in the first project folder that has it.
    static func transcriptFile(sessionID: String, projectsDirectory: URL) -> URL? {
        guard isValidSessionID(sessionID) else { return nil }
        let manager = FileManager.default
        guard let projects = try? manager.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: nil
        ) else { return nil }
        return projects.sorted(by: { $0.path < $1.path })
            .map { $0.appendingPathComponent("\(sessionID).jsonl") }
            .first { manager.isReadableFile(atPath: $0.path) }
    }

    /// The `cwd` on the first transcript line that has one, if that folder exists.
    static func transcriptDirectory(sessionID: String, projectsDirectory: URL) -> String? {
        guard let transcript = transcriptFile(sessionID: sessionID, projectsDirectory: projectsDirectory),
              let handle = try? FileHandle(forReadingFrom: transcript) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1_048_576) else { return nil }
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let cwd = object["cwd"] as? String else { continue }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue {
                return cwd
            }
            return nil
        }
        return nil
    }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isValidKey(_ key: String) -> Bool {
        let scalars = Array(key.unicodeScalars)
        guard let dash = scalars.lastIndex(of: "-"), dash >= 2, dash < scalars.count - 1 else { return false }
        let project = scalars[..<dash]
        let number = scalars[(dash + 1)...]
        func upper(_ s: Unicode.Scalar) -> Bool { s.value >= 65 && s.value <= 90 }
        func digit(_ s: Unicode.Scalar) -> Bool { s.value >= 48 && s.value <= 57 }
        return upper(project[0])
            && project.dropFirst().allSatisfy { upper($0) || digit($0) }
            && number.allSatisfy(digit)
    }

    private static func isValidSessionID(_ id: String) -> Bool {
        let scalars = Array(id.unicodeScalars)
        guard let first = scalars.first else { return false }
        func alnum(_ s: Unicode.Scalar) -> Bool {
            (s.value >= 48 && s.value <= 57) || (s.value >= 65 && s.value <= 90) || (s.value >= 97 && s.value <= 122)
        }
        return (alnum(first) || first == "_" || first == "-")
            && scalars.allSatisfy { alnum($0) || $0 == "_" || $0 == "-" || $0 == "." }
    }
}
