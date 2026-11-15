import Foundation
import Testing
@testable import TicketPilotCore

@Suite(.timeLimit(.minutes(1))) struct ConfigEditorTests {
    static let config = """
    {
      "jira": {"site": "https://example.atlassian.net", "email": "me@example.com", "keychain_service": "tp"},
      "repos": [{"name": "ios", "path": "~/r/ios", "main_branch": "main", "review": "github",
                 "match": {"title_prefixes": ["[iOS]"], "labels": []}}],
      "terminal_app": "Terminal",
      "max_commit_lines": 999,
      "ratio": 1.50,
      "note": "caf\\u00e9 \\"quoted\\" a/b",
      "flag": true,
      "nothing": null,
      "stuck_minutes": {}
    }
    """

    static func edit(_ name: String?, in text: String = config) throws -> String {
        String(decoding: try ConfigEditor.setTerminalApp(name, in: Data(text.utf8)), as: UTF8.self)
    }

    static func object(_ text: String) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
    }

    @Test func test_replacesTheTerminalInPlaceAndKeepsEveryOtherKey() throws {
        let output = try Self.edit("Ghostty")
        let before = try Self.object(Self.config).mutableCopy() as! NSMutableDictionary
        before["terminal_app"] = "Ghostty"
        #expect(try Self.object(output) == before)
        // The keys keep their order, and the values their spelling.
        let keys = ["jira", "repos", "terminal_app", "max_commit_lines", "ratio", "note", "flag", "nothing", "stuck_minutes"]
        let positions = keys.map { output.range(of: "\"\($0)\"")!.lowerBound }
        #expect(positions == positions.sorted())
        #expect(output.contains("\"ratio\": 1.50"))
        #expect(output.contains(#""note": "caf\u00e9 \"quoted\" a/b""#))
        #expect(output.contains(#""title_prefixes": ["[iOS]"]"#))
        #expect(output.contains(#""labels": []"#))
        #expect(output.contains(#""stuck_minutes": {}"#))
        #expect(output.hasSuffix("}\n"))
    }

    @Test func test_isPrettyPrintedWithTwoSpaces() throws {
        let output = try Self.edit("iTerm", in: #"{"a":{"b":[1,{"c":2}]}}"#)
        #expect(output == """
        {
          "a": {
            "b": [
              1,
              {
                "c": 2
              }
            ]
          },
          "terminal_app": "iTerm"
        }

        """)
    }

    @Test func test_addsTheTerminalAtTheEndWhenMissing() throws {
        let output = try Self.edit("Warp", in: #"{"poll_minutes": 5}"#)
        #expect(output == "{\n  \"poll_minutes\": 5,\n  \"terminal_app\": \"Warp\"\n}\n")
    }

    @Test func test_automaticRemovesTheKey() throws {
        let output = try Self.edit(nil)
        #expect(try Self.object(output)["terminal_app"] == nil)
        #expect(try Self.object(output).count == 8)
        #expect(try Self.edit(nil, in: #"{"terminal_app": "x"}"#) == "{}\n")
        #expect(try Self.edit(nil, in: #"{"a": 1}"#) == "{\n  \"a\": 1\n}\n")
    }

    @Test func test_theLastOfDuplicateKeysIsReplacedAndTheOthersRemoved() throws {
        let text = #"{"terminal_app": "A", "a": 1, "terminal_app": "B", "b": 2}"#
        #expect(try Self.edit("Warp", in: text) == "{\n  \"a\": 1,\n  \"terminal_app\": \"Warp\",\n  \"b\": 2\n}\n")
        #expect(try Self.edit(nil, in: text) == "{\n  \"a\": 1,\n  \"b\": 2\n}\n")
    }

    @Test func test_keepsRawUTF8BigIntegersAndTrailingBackslashes() throws {
        let text = #"{"name": "café 日本", "big": 123456789012345678901234567890, "dir": "C:\\", "x": -1.5e+3}"#
        let output = try Self.edit("Warp", in: text)
        #expect(output.contains(#""name": "café 日本""#))
        #expect(output.contains(#""big": 123456789012345678901234567890"#))
        #expect(output.contains(#""dir": "C:\\""#))
        #expect(output.contains(#""x": -1.5e+3"#))
    }

    @Test func test_dropsAByteOrderMark() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(#"{"a": 1}"#.utf8)
        let output = String(decoding: try ConfigEditor.setTerminalApp("Warp", in: data), as: UTF8.self)
        #expect(output == "{\n  \"a\": 1,\n  \"terminal_app\": \"Warp\"\n}\n")
    }

    @Test func test_escapesTheName() throws {
        let output = try Self.edit(#"My "Term""#, in: "{}")
        #expect(try Self.object(output)["terminal_app"] as? String == #"My "Term""#)
    }

    @Test func test_refusesWhatIsNotAJSONObject() {
        #expect(throws: ConfigEditError.invalidJSON) { try Self.edit("Warp", in: "{\"a\": ") }
        #expect(throws: ConfigEditError.invalidJSON) { try Self.edit("Warp", in: "{\"a\": 1} trailing") }
        #expect(throws: ConfigEditError.notAnObject) { try Self.edit("Warp", in: "[1, 2]") }
    }

    // MARK: - Guided setup

    static func string(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    @Test func test_fillJiraCreatesAConfig() throws {
        let data = try ConfigEditor.fillJira(site: URL(string: "https://acme.atlassian.net")!, in: nil)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tp-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let config = try AppConfig.load(from: url)
        #expect(config.jira.site == URL(string: "https://acme.atlassian.net")!)
        #expect(config.repos.isEmpty)
    }

    @Test func test_fillJiraKeepsWhatIsWritten() throws {
        let text = #"{"jira": {"site": "https://mine.atlassian.net", "auth": "api_token"}, "repos": [], "poll_minutes": 2}"#
        let output = Self.string(try ConfigEditor.fillJira(
            site: URL(string: "https://acme.atlassian.net")!, in: Data(text.utf8)
        ))
        let jira = try #require(try Self.object(output)["jira"] as? NSDictionary)
        #expect(jira["site"] as? String == "https://mine.atlassian.net")
        #expect(jira["auth"] as? String == "api_token")
        #expect(try Self.object(output)["poll_minutes"] as? Int == 2)
    }

    static let web = RepoEntry(
        name: "web", path: "/r/web", mainBranch: "master", review: "github",
        titlePrefixes: ["[Web]"], labels: ["Web"], components: ["Web"]
    )

    @Test func test_addRepoAppendsAnEntryAppConfigReads() throws {
        let output = try ConfigEditor.addRepo(Self.web, in: Data(Self.config.utf8))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tp-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try output.write(to: url)
        let config = try AppConfig.load(from: url)
        #expect(config.repos.map(\.name) == ["ios", "web"])
        #expect(config.repos[1].path == "/r/web")
        #expect(config.repos[1].mainBranch == "master")
        #expect(config.repos[1].review == "github")
        #expect(config.repos[1].match.titlePrefixes == ["[Web]"])
        #expect(config.repos[1].match.components == ["Web"])
        #expect(try Self.object(Self.string(output))["terminal_app"] as? String == "Terminal")
    }

    /// The file stays readable by hand: `/` is written as is, not as `\/`.
    @Test func test_pathsAreWrittenWithoutEscapedSlashes() throws {
        let output = Self.string(try ConfigEditor.addRepo(Self.web, in: Data(Self.config.utf8)))
        #expect(output.contains(#""path": "/r/web""#))
        let jira = Self.string(try ConfigEditor.fillJira(site: URL(string: "https://acme.atlassian.net")!, in: nil))
        #expect(jira.contains(#""site": "https://acme.atlassian.net""#))
    }

    @Test func test_addRepoWithoutReviewWritesNone() throws {
        var entry = Self.web
        entry.review = nil
        let output = try ConfigEditor.addRepo(entry, in: Data(Self.config.utf8))
        let repos = try #require(try Self.object(Self.string(output))["repos"] as? [NSDictionary])
        #expect(repos[1]["review"] == nil)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tp-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try output.write(to: url)
        #expect(try AppConfig.load(from: url).repos[1].review == nil)
    }

    @Test func test_addRepoCreatesTheListWhenAbsent() throws {
        let output = try ConfigEditor.addRepo(Self.web, in: Data(#"{"jira": {}}"#.utf8))
        let repos = try #require(try Self.object(Self.string(output))["repos"] as? [NSDictionary])
        #expect(repos.map { $0["name"] as? String } == ["web"])
    }

    @Test func test_removeRepoKeepsTheOthers() throws {
        let two = try ConfigEditor.addRepo(Self.web, in: Data(Self.config.utf8))
        let output = Self.string(try ConfigEditor.removeRepo(named: "ios", in: two))
        let repos = try #require(try Self.object(output)["repos"] as? [NSDictionary])
        #expect(repos.map { $0["name"] as? String } == ["web"])
        #expect(try Self.object(output)["max_commit_lines"] as? Int == 999)
    }
}
