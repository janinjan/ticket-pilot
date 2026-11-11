import Foundation
import Testing
@testable import TicketPilotCore

struct AppConfigTests {
    private func writeTemp(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tp-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func test_decodesExampleConfig() throws {
        let example = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../config.example.json")
            .standardizedFileURL
        let config = try AppConfig.load(from: example)
        #expect(config.repos.map(\.name) == ["ios", "android", "web"])
        #expect(config.repos[0].match.titlePrefixes == ["[iOS]"])
        #expect(config.pollMinutes == 5)
        #expect(config.readyStatuses == ["To Start"])
        #expect(config.terminalApp == "Terminal")
        #expect(config.gitClient == "GitHub Desktop")
        #expect(config.repos[0].editor == "Xcode")
        #expect(config.repos[1].editor == nil)
        #expect(config.jira.keychainService == "ticket-pilot-jira")
    }

    @Test func test_defaultsWhenOptionalKeysAreMissing() throws {
        let url = try writeTemp("""
        {"jira": {"site": "https://example.atlassian.net", "email": "a@example.com",
                  "keychain_service": "svc"},
         "repos": [{"name": "ios", "path": "/p", "main_branch": "main", "review": "github"}]}
        """)
        let config = try AppConfig.load(from: url)
        #expect(config.pollMinutes == 5)
        #expect(config.readyStatuses == ["To Start"])
        #expect(config.terminalApp == nil)
        #expect(config.gitClient == nil)
        #expect(config.permissionMode == nil)
        #expect(config.stuckMinutes == [:])
        #expect(config.repos[0].match.labels == [])
        #expect(config.jira.auth == .mcp)

        let overridden = try AppConfig.load(from: writeTemp("""
        {"jira": {"site": "https://example.atlassian.net", "email": "a@example.com",
                  "keychain_service": "svc"},
         "repos": [], "poll_minutes": 2, "ready_statuses": ["Ready"],
         "terminal_app": "iTerm", "permission_mode": "plan",
         "stuck_minutes": {"app_test": 90, "plan": 30}}
        """))
        #expect(overridden.pollMinutes == 2)
        #expect(overridden.readyStatuses == ["Ready"])
        #expect(overridden.terminalApp == "iTerm")
        #expect(overridden.permissionMode == "plan")
        #expect(overridden.stuckMinutes == ["app_test": 90, "plan": 30])
    }

    @Test func test_missingFileThrowsMissing() {
        let url = URL(fileURLWithPath: "/tmp/tp-does-not-exist-\(UUID().uuidString).json")
        #expect(throws: ConfigError.missing(path: url.path)) {
            try AppConfig.load(from: url)
        }
    }

    @Test func test_invalidJSONThrowsInvalid() throws {
        let url = try writeTemp("{ not json")
        do {
            _ = try AppConfig.load(from: url)
            Issue.record("expected an error")
        } catch {
            guard case .invalid = error else {
                Issue.record("expected .invalid, got \(error)")
                return
            }
        }
    }

    @Test func test_pathsFollowEnvironmentOverrides() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let overridden = StatePaths(
            environment: ["TICKET_PILOT_HOME": "/tmp/tp", "TICKET_PILOT_CONFIG": "/tmp/c.json"],
            home: home
        )
        #expect(overridden.runsDirectory.path == "/tmp/tp/runs")
        #expect(overridden.appDirectory.path == "/tmp/tp/app")
        #expect(overridden.configFile.path == "/tmp/c.json")

        let plain = StatePaths(environment: [:], home: home)
        #expect(plain.stateHome.path == "/Users/someone/Library/Application Support/ticket-pilot")
        #expect(plain.configFile.path == "/Users/someone/.config/ticket-pilot/config.json")
    }

    @Test func test_browseURLAndExpandedPath() throws {
        let url = try writeTemp("""
        {"jira": {"site": "https://example.atlassian.net", "email": "a@example.com", "keychain_service": "svc"},
         "repos": [{"name": "ios", "path": "~/repos/ios", "main_branch": "main", "review": "github"}]}
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        let config = try AppConfig.load(from: url)
        #expect(config.jira.browseURL(key: "ABC-1").absoluteString == "https://example.atlassian.net/browse/ABC-1")
        #expect(config.repos[0].expandedPath == NSHomeDirectory() + "/repos/ios")
    }

    @Test func test_readsTheJiraAuth() throws {
        func config(_ auth: String) throws -> AppConfig {
            try AppConfig.load(from: try writeTemp("""
            {"jira": {"site": "https://example.atlassian.net", "email": "a@example.com",
                      "keychain_service": "svc", "auth": "\(auth)"}, "repos": []}
            """))
        }
        #expect(try config("mcp").jira.auth == .mcp)
        #expect(try config("api_token").jira.auth == .apiToken)
        #expect(throws: ConfigError.self) { try config("password") }
    }
}
