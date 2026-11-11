import Foundation
import Testing
@testable import TicketPilotCore

final class FakeRunner: ProcessRunning, @unchecked Sendable {
    struct Call: Equatable { var executable: String; var arguments: [String] }
    private let lock = NSLock()
    private var stored: [Call] = []
    var calls: [Call] { lock.withLock { stored } }

    func run(_ executable: String, _ arguments: [String], currentDirectory: URL?) throws -> ProcessResult {
        lock.withLock { stored.append(Call(executable: executable, arguments: arguments)) }
        return ProcessResult(status: 0, output: "", error: "")
    }
}

@Suite(.timeLimit(.minutes(1))) struct TerminalLauncherTests {
    func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tp-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func launcherWritesExecutableScriptAndOpensIt() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = FakeRunner()
        let launcher = TerminalLauncher(appName: "Ghostty", scriptsDirectory: dir, runner: runner)
        try launcher.open(command: "cd '/w' && claude")

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.count == 1)
        let file = dir.appendingPathComponent(try #require(files.first))
        #expect(file.pathExtension == "command")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        #expect(try String(contentsOf: file, encoding: .utf8) == "#!/bin/zsh -l\ncd '/w' && claude\n")
        #expect(runner.calls == [.init(executable: "/usr/bin/open", arguments: ["-a", "Ghostty", file.path])])
    }

    @Test func launcherCreatesMissingDirectory() throws {
        let dir = try makeDirectory().appendingPathComponent("launch")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let launcher = TerminalLauncher(appName: "Terminal", scriptsDirectory: dir, runner: FakeRunner())
        try launcher.open(command: "true")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 1)
    }

    @Test func launcherRemovesOldScripts() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let old = dir.appendingPathComponent("old.command")
        let recent = dir.appendingPathComponent("recent.command")
        for (url, age) in [(old, 25 * 3600.0), (recent, 3600.0)] {
            try "x".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        let launcher = TerminalLauncher(appName: "Ghostty", scriptsDirectory: dir, runner: FakeRunner())
        try launcher.open(command: "true", now: now)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
    }

    @Test func activateOpensApp() throws {
        let runner = FakeRunner()
        let launcher = TerminalLauncher(appName: "Ghostty", scriptsDirectory: URL(fileURLWithPath: "/nonexistent"), runner: runner)
        try launcher.activate()
        #expect(runner.calls == [.init(executable: "/usr/bin/open", arguments: ["-a", "Ghostty"])])
    }
}
