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

    // MARK: - jira.auth

    static func editAuth(_ value: String, in text: String = config) throws -> String {
        String(decoding: try ConfigEditor.setJiraAuth(value, in: Data(text.utf8)), as: UTF8.self)
    }

    @Test func test_setsTheJiraAuthInsideJiraAndKeepsEverythingElse() throws {
        let output = try Self.editAuth("api_token")
        let before = try Self.object(Self.config).mutableCopy() as! NSMutableDictionary
        let jira = (before["jira"] as! NSDictionary).mutableCopy() as! NSMutableDictionary
        jira["auth"] = "api_token"
        before["jira"] = jira
        #expect(try Self.object(output) == before)
        #expect(output.contains("\"ratio\": 1.50"))
        #expect(output.contains(#""keychain_service": "tp",\#n    "auth": "api_token""#))
    }

    @Test func test_replacesAnExistingJiraAuth() throws {
        let output = try Self.editAuth("mcp", in: #"{"jira": {"auth": "api_token", "site": "s"}}"#)
        #expect(output == "{\n  \"jira\": {\n    \"auth\": \"mcp\",\n    \"site\": \"s\"\n  }\n}\n")
    }

    @Test func test_jiraAuthNeedsAJiraObject() {
        #expect(throws: ConfigEditError.notAnObject) { try Self.editAuth("mcp", in: #"{"jira": 1}"#) }
        #expect(throws: ConfigEditError.notAnObject) { try Self.editAuth("mcp", in: #"{"repos": []}"#) }
    }
}
