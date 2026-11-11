import Foundation

/// Opens a command in the user's terminal app through a throwaway `.command` script.
public struct TerminalLauncher: Sendable {
    public var appName: String
    public var scriptsDirectory: URL
    public var runner: ProcessRunning

    private static let maxScriptAge: TimeInterval = 24 * 3600

    public init(appName: String, scriptsDirectory: URL, runner: ProcessRunning) {
        self.appName = appName
        self.scriptsDirectory = scriptsDirectory
        self.runner = runner
    }

    public func open(command: String, now: Date = Date()) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
        removeOldScripts(now: now)
        let file = scriptsDirectory.appendingPathComponent("\(UUID().uuidString).command")
        try "#!/bin/zsh -l\n\(command)\n".write(to: file, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        try launch(["-a", appName, file.path])
    }

    public func activate() throws {
        try launch(["-a", appName])
    }

    private func launch(_ arguments: [String]) throws {
        let result = try runner.run("/usr/bin/open", arguments, currentDirectory: nil)
        guard result.status == 0 else {
            throw TerminalLauncherError.openFailed(result.error.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func removeOldScripts(now: Date) {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: scriptsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for url in urls where url.pathExtension == "command" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) > Self.maxScriptAge {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}

public enum TerminalLauncherError: Error, Equatable {
    case openFailed(String)
}
