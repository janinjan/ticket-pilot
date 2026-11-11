import Foundation
import Testing
@testable import TicketPilotCore

@Suite(.timeLimit(.minutes(1))) struct SessionCommandTests {
    @Test func startCommand() throws {
        #expect(
            try SessionCommand.start(key: "ABC-1", repoPath: "/w/app", permissionMode: nil)
                == "cd '/w/app' && claude '/ticket-pilot:start ABC-1'"
        )
        #expect(
            try SessionCommand.start(key: "ABC-1", repoPath: "/w/app", permissionMode: "acceptEdits")
                == "cd '/w/app' && claude --permission-mode 'acceptEdits' '/ticket-pilot:start ABC-1'"
        )
    }

    @Test func resumeCommand() throws {
        #expect(
            try SessionCommand.resume(sessionID: "s-1", directory: "/w/wt")
                == "cd '/w/wt' && claude --resume 's-1'"
        )
    }

    @Test func quotesPathsWithSpacesAndQuotes() throws {
        let path = "/Users/x/My Repos/l'app"
        let start = try SessionCommand.start(key: "ABC-1", repoPath: path, permissionMode: "it's")
        #expect(start.hasPrefix("cd '/Users/x/My Repos/l'\\''app' && "))
        #expect(start.contains("--permission-mode 'it'\\''s'"))
        let resume = try SessionCommand.resume(sessionID: "s-1", directory: path)
        #expect(resume == "cd '/Users/x/My Repos/l'\\''app' && claude --resume 's-1'")
    }

    @Test func rejectsInvalidKeyAndSessionID() {
        for key in ["abc-1", "ABC-1; rm -rf ~", "ABC-1\n"] {
            #expect(throws: SessionCommandError.invalidKey(key)) {
                try SessionCommand.start(key: key, repoPath: "/w", permissionMode: nil)
            }
        }
        for id in ["../x", "", ".hidden", "a b", "s-1\n"] {
            #expect(throws: SessionCommandError.invalidSessionID(id)) {
                try SessionCommand.resume(sessionID: id, directory: "/w")
            }
        }
    }

    private func run(sessionID: String?, worktree: String?) -> Run {
        Run(
            id: "ABC-1--ios", key: "ABC-1", repo: "ios", repoPath: "/w/app", worktree: worktree,
            branch: nil, sessionID: sessionID,
            session: nil, step: 3, stepName: "research", status: .waiting,
            waiting: nil, history: [], updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test func test_resumeRunUsesWorktreeThenRepo() throws {
        #expect(
            try SessionCommand.resume(run(sessionID: "s-1", worktree: "/w/wt"), permissionMode: nil, projectsDirectory: emptyProjects())
                == "cd '/w/wt' && claude --resume 's-1'"
        )
        #expect(
            try SessionCommand.resume(run(sessionID: "s-1", worktree: nil), permissionMode: nil, projectsDirectory: emptyProjects())
                == "cd '/w/app' && claude --resume 's-1'"
        )
    }

    @Test func test_resumeRunWithoutSessionStartsAgain() throws {
        #expect(
            try SessionCommand.resume(run(sessionID: nil, worktree: "/w/wt"), permissionMode: "plan", projectsDirectory: emptyProjects())
                == "cd '/w/app' && claude --permission-mode 'plan' '/ticket-pilot:start ABC-1'"
        )
    }

    private func emptyProjects() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tp-none-\(UUID().uuidString)")
    }

    /// A projects dir holding `<project>/s-1.jsonl` whose lines come from `lines(startFolder)`
    /// (nil: no transcript); `startFolder` is a real folder.
    private func fixture(_ lines: ((String) -> [String])?) throws -> (projects: URL, startFolder: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tp-\(UUID().uuidString)")
        let start = root.appendingPathComponent("started-here")
        let project = root.appendingPathComponent("projects/-Users-x-Developer")
        try FileManager.default.createDirectory(at: start, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        if let lines {
            try lines(start.path).joined(separator: "\n").write(
                to: project.appendingPathComponent("s-1.jsonl"), atomically: true, encoding: .utf8
            )
        }
        return (root.appendingPathComponent("projects"), start.path)
    }

    private func directory(_ fixture: (projects: URL, startFolder: String)) -> String {
        SessionCommand.resumeDirectory(
            for: run(sessionID: "s-1", worktree: "/w/wt"),
            projectsDirectory: fixture.projects
        )
    }

    @Test func test_resumeDirectoryReadsCwdOnFirstLine() throws {
        let f = try fixture { ["{\"type\":\"user\",\"cwd\":\"\($0)\"}"] }
        #expect(directory(f) == f.startFolder)
    }

    @Test func test_resumeDirectoryReadsCwdLaterInTranscript() throws {
        let f = try fixture { ["{\"type\":\"summary\"}", "not json", "{\"cwd\":\"\($0)\"}"] }
        #expect(directory(f) == f.startFolder)
    }

    @Test func test_resumeDirectoryFallsBackWithoutCwd() throws {
        let f = try fixture { _ in ["{\"type\":\"summary\"}"] }
        #expect(directory(f) == "/w/wt")
    }

    @Test func test_resumeDirectoryFallsBackWithoutTranscript() throws {
        let f = try fixture(nil)
        #expect(directory(f) == "/w/wt")
    }

    @Test func test_resumeDirectoryFallsBackWhenCwdDoesNotExist() throws {
        let f = try fixture { _ in ["{\"cwd\":\"/nonexistent/tp-folder\"}"] }
        #expect(directory(f) == "/w/wt")
    }

    @Test func test_resumeRunUsesTranscriptDirectory() throws {
        let f = try fixture { ["{\"cwd\":\"\($0)\"}"] }
        #expect(
            try SessionCommand.resume(
                run(sessionID: "s-1", worktree: "/w/wt"), permissionMode: nil, projectsDirectory: f.projects
            ) == "cd '\(f.startFolder)' && claude --resume 's-1'"
        )
    }
}
