import Foundation

/// The terminal app sessions are opened in.
public struct TerminalChoice: Equatable, Sendable {
    /// The name given to `open -a`.
    public var appName: String

    /// Terminals the app can pick without being told, by the name of their `.app` bundle.
    public static let knownTerminals = ["Ghostty", "iTerm", "Warp", "WezTerm", "kitty"]

    /// Ghostty is scriptable: sessions are opened in, and found by, its tabs.
    public init(appName: String) {
        self.appName = appName
    }

    public var isGhostty: Bool {
        appName.caseInsensitiveCompare("Ghostty") == .orderedSame
    }

    /// In order: the configured `terminal_app`; the known terminal hosting a running Claude Code; the
    /// only known terminal installed; the app macOS opens `.command` files with; Terminal.
    public static func resolve(
        configured: String?,
        hostOfRunningClaude: String?,
        installedTerminals: [String],
        systemDefault: URL?
    ) -> TerminalChoice {
        if let name = configured?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return TerminalChoice(appName: name)
        }
        if let host = hostOfRunningClaude.flatMap(known) {
            return TerminalChoice(appName: host)
        }
        let installed = knownTerminals.filter { name in
            installedTerminals.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        if installed.count == 1 {
            return TerminalChoice(appName: installed[0])
        }
        if let systemDefault {
            let name = systemDefault.deletingPathExtension().lastPathComponent
            if !name.isEmpty { return TerminalChoice(appName: name) }
        }
        return TerminalChoice(appName: "Terminal")
    }

    /// The terminals Settings offers besides "Automatic": the installed known ones, Terminal, and the
    /// configured `terminal_app` when it is none of those.
    public static func options(installed: [String], configured: String?) -> [String] {
        var names = knownTerminals.filter { name in
            installed.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        } + ["Terminal"]
        if let name = configured?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
           !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            names.append(name)
        }
        return names
    }

    /// The option of `options` (from `options(installed:configured:)`, which always holds the configured
    /// name) that `configured` names, nil for "Automatic".
    public static func selectedOption(configured: String?, in options: [String]) -> String? {
        guard let name = configured?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return options.first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The canonical name of a known terminal; "iTerm2" is how iTerm often calls itself.
    static func known(_ name: String) -> String? {
        let name = name.caseInsensitiveCompare("iTerm2") == .orderedSame ? "iTerm" : name
        return knownTerminals.first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// Finds out, from the machine, the inputs of `TerminalChoice.resolve`.
public struct TerminalDetector: Sendable {
    public var runner: ProcessRunning
    public var applicationDirectories: [URL]

    public init(runner: ProcessRunning, applicationDirectories: [URL] = TerminalDetector.defaultDirectories) {
        self.runner = runner
        self.applicationDirectories = applicationDirectories
    }

    public static var defaultDirectories: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    /// Known terminals found in the application folders.
    public func installedTerminals() -> [String] {
        let fileManager = FileManager.default
        return TerminalChoice.knownTerminals.filter { name in
            applicationDirectories.contains {
                fileManager.fileExists(atPath: $0.appendingPathComponent("\(name).app").path)
            }
        }
    }

    /// The `.app` hosting the first running `claude` whose process ancestry leads to a known terminal.
    public func hostOfRunningClaude() -> String? {
        guard let result = try? runner.run("/bin/ps", ["-axo", "pid=,ppid=,comm="], currentDirectory: nil),
              result.status == 0
        else { return nil }
        return Self.host(inProcessTable: result.output)
    }

    /// `ps -axo pid=,ppid=,comm=` output in, the known terminal hosting a `claude` process out.
    static func host(inProcessTable table: String) -> String? {
        var parents: [Int: Int] = [:]
        var commands: [Int: String] = [:]
        for line in table.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int(fields[0]), let parent = Int(fields[1]) else { continue }
            parents[pid] = parent
            commands[pid] = fields[2].trimmingCharacters(in: .whitespaces)
        }
        for pid in commands.keys.sorted() where commands[pid].map({ $0 == "claude" || $0.hasSuffix("/claude") }) == true {
            var current = pid
            var seen: Set<Int> = []
            while let parent = parents[current], seen.insert(current).inserted {
                if let bundle = commands[parent].flatMap(Self.outermostBundleName) {
                    if let known = TerminalChoice.known(bundle) { return known }
                    break
                }
                current = parent
            }
        }
        return nil
    }

    private static func outermostBundleName(_ path: String) -> String? {
        path.split(separator: "/").first { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
    }
}
