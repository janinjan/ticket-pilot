import Foundation
import Testing
@testable import TicketPilotCore

/// Answers tool calls from a table and records them.
final class FakeTools: MCPToolCalling, @unchecked Sendable {
    typealias Handler = @Sendable (String, [String: JSONValue]) throws(MCPError) -> MCPToolResult

    private let lock = NSLock()
    private var log: [(name: String, arguments: [String: JSONValue])] = []
    private let tools: [MCPTool]
    private let handler: Handler

    init(tools: [MCPTool] = MCPJiraFixtures.tools, handler: @escaping Handler) {
        self.tools = tools
        self.handler = handler
    }

    var calls: [(name: String, arguments: [String: JSONValue])] {
        lock.withLock { log }
    }

    func listTools() async throws(MCPError) -> [MCPTool] {
        tools
    }

    func callTool(_ name: String, arguments: [String: JSONValue]) async throws(MCPError) -> MCPToolResult {
        lock.withLock { log.append((name, arguments)) }
        return try handler(name, arguments)
    }
}

func text(_ value: String, isError: Bool = false) -> MCPToolResult {
    MCPToolResult(texts: [value], structured: nil, isError: isError)
}

/// Results shaped like the Atlassian MCP server's: JSON text in the first content item.
enum MCPJiraFixtures {
    static let tools = [
        MCPTool(name: "atlassianUserInfo", properties: []),
        MCPTool(name: "getAccessibleAtlassianResources", properties: []),
        MCPTool(name: "searchJiraIssuesUsingJql", properties: [
            "cloudId", "fields", "jql", "maxResults", "nextPageToken", "responseContentFormat",
        ]),
    ]

    static let resources = """
    [{"id":"11111111-2222-3333-4444-555555555555","url":"https://other.atlassian.net","name":"other",\
    "scopes":["read:jira-work"],"avatarUrl":"https://site-admin-avatar-cdn.prod.public.atl-paas.net/avatars/240/rocket.png"},\
    {"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","url":"https://example.atlassian.net","name":"example",\
    "scopes":["read:jira-work","write:jira-work"],"avatarUrl":"https://site-admin-avatar-cdn.prod.public.atl-paas.net/avatars/240/site.png"}]
    """

    static let userInfo = """
    {"account_id":"712020:0e1f","email":"me@example.com","name":"Me","picture":"https://avatar.example.com/me.png",\
    "account_status":"active","characteristics":{"not_mentionable":false},"last_updated":"2026-01-01T00:00:00.000Z",\
    "nickname":"me","zoneinfo":"Europe/Paris","locale":"en-GB","extended_profile":{}}
    """

    static func issue(_ key: String, status: String = "To Start", category: String = "new", categoryName: String = "To Do") -> String {
        """
        {"expand":"renderedFields,names,schema","id":"1\(key.filter(\.isNumber))","self":"https://example.atlassian.net/rest/api/3/issue/1",\
        "key":"\(key)","fields":{"summary":"Summary \(key)","status":{"self":"https://example.atlassian.net/rest/api/3/status/1",\
        "description":"","iconUrl":"https://example.atlassian.net/","name":"\(status)","id":"10000",\
        "statusCategory":{"self":"https://example.atlassian.net/rest/api/3/statuscategory/2","id":2,"key":"\(category)",\
        "colorName":"blue-gray","name":"\(categoryName)"}},"labels":["ios","fast"],\
        "components":[{"self":"https://example.atlassian.net/rest/api/3/component/1","id":"10100","name":"iOS"}]}}
        """
    }

    static func page(_ issues: [String], next: String? = nil) -> String {
        let token = next.map { #","nextPageToken":"\#($0)""# } ?? ""
        return #"{"issues":[\#(issues.joined(separator: ","))]\#(token),"isLast":\#(next == nil)}"#
    }
}

struct MCPJiraClientTests {
    static let site = URL(string: "https://example.atlassian.net")!

    private func standard(
        search: @escaping @Sendable ([String: JSONValue]) throws(MCPError) -> MCPToolResult = { _ in
            text(MCPJiraFixtures.page([MCPJiraFixtures.issue("ABC-1")]))
        }
    ) -> FakeTools {
        FakeTools { name, arguments throws(MCPError) in
            switch name {
            case "getAccessibleAtlassianResources": return text(MCPJiraFixtures.resources)
            case "atlassianUserInfo": return text(MCPJiraFixtures.userInfo)
            case "searchJiraIssuesUsingJql": return try search(arguments)
            default: throw .tool("unknown tool \(name)")
            }
        }
    }

    @Test func test_searchesTheSiteCloudWithTheSpecQuery() async throws {
        let tools = standard()
        let jira = MCPJiraClient(site: Self.site, tools: tools)
        let issues = try await jira.openAssignedIssues()

        #expect(issues == [JiraIssue(
            key: "ABC-1", summary: "Summary ABC-1", statusName: "To Start", statusCategory: .toDo,
            labels: ["ios", "fast"], components: ["iOS"]
        )])
        #expect(tools.calls.map(\.name) == ["getAccessibleAtlassianResources", "searchJiraIssuesUsingJql"])
        let arguments = tools.calls[1].arguments
        #expect(arguments["cloudId"] == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        #expect(arguments["jql"] == "assignee = currentUser() AND statusCategory != Done")
        #expect(arguments["fields"] == ["summary", "status", "labels", "components"])
        #expect(arguments["maxResults"] == 100)
        #expect(arguments["nextPageToken"] == nil)
    }

    @Test func test_looksTheCloudUpOnce() async throws {
        let tools = standard()
        let jira = MCPJiraClient(site: Self.site, tools: tools)
        _ = try await jira.openAssignedIssues()
        _ = try await jira.openAssignedIssues()
        #expect(tools.calls.filter { $0.name == "getAccessibleAtlassianResources" }.count == 1)
    }

    @Test func test_followsNextPageToken() async throws {
        let tools = standard { arguments in
            if arguments["nextPageToken"] == "p2" {
                return text(MCPJiraFixtures.page([MCPJiraFixtures.issue("ABC-2")]))
            }
            return text(MCPJiraFixtures.page([MCPJiraFixtures.issue("ABC-1")], next: "p2"))
        }
        let jira = MCPJiraClient(site: Self.site, tools: tools)
        #expect(try await jira.openAssignedIssues().map(\.key) == ["ABC-1", "ABC-2"])
    }

    @Test func test_mapsStatusCategories() async throws {
        let tools = standard { arguments in
            #expect(arguments["jql"] == "key in (ABC-1, ABC-2, ABC-3)")
            return text(MCPJiraFixtures.page([
                MCPJiraFixtures.issue("ABC-1", category: "done", categoryName: "Done"),
                MCPJiraFixtures.issue("ABC-2", category: "indeterminate", categoryName: "In Progress"),
                MCPJiraFixtures.issue("ABC-3", category: "undefined", categoryName: "No Category"),
            ]))
        }
        let jira = MCPJiraClient(site: Self.site, tools: tools)
        let categories = try await jira.statusCategories(of: ["ABC-1", "ABC-2", "ABC-3"])
        #expect(categories == ["ABC-1": .done, "ABC-2": .inProgress, "ABC-3": .toDo])
    }

    @Test func test_statusCategoriesOfNoKeysCallsNothing() async throws {
        let tools = standard()
        let jira = MCPJiraClient(site: Self.site, tools: tools)
        #expect(try await jira.statusCategories(of: []) == [:])
        #expect(tools.calls.isEmpty)
    }

    @Test func test_toleratesMissingFields() {
        let json = """
        {"issues":[{"key":"ABC-1","fields":{"summary":"Only a summary"}},\
        {"key":"ABC-2","fields":{"status":{"name":"Doing","statusCategory":{"name":"In Progress"}},"components":["Web"]}},\
        {"id":"no key"}]}
        """
        let page = MCPJiraClient.parseSearch(text(json))
        #expect(page?.issues == [
            JiraIssue(key: "ABC-1", summary: "Only a summary", statusName: "", statusCategory: .toDo),
            JiraIssue(key: "ABC-2", summary: "", statusName: "Doing", statusCategory: .inProgress, components: ["Web"]),
        ])
        #expect(page?.nextPageToken == nil)
    }

    @Test func test_readsIssuesWrappedOrInStructuredContent() {
        let wrapped = MCPJiraClient.parseSearch(text(#"{"data":{"issues":[{"key":"ABC-1","fields":{}}]}}"#))
        #expect(wrapped?.issues.map(\.key) == ["ABC-1"])
        let structured = MCPJiraClient.parseSearch(MCPToolResult(
            texts: ["Found 1 issue"], structured: Data(#"{"issues":[{"key":"ABC-2"}]}"#.utf8), isError: false
        ))
        #expect(structured?.issues.map(\.key) == ["ABC-2"])
        #expect(MCPJiraClient.parseSearch(text("No JSON here")) == nil)
    }

    @Test func test_adaptsToTheToolArguments() async throws {
        let tools = FakeTools(tools: [
            MCPTool(name: "getAccessibleAtlassianResources", properties: []),
            MCPTool(name: "searchJiraIssuesUsingJql", properties: ["cloud_id", "jql"]),
        ]) { name, _ throws(MCPError) in
            name == "getAccessibleAtlassianResources"
                ? text(MCPJiraFixtures.resources)
                : text(MCPJiraFixtures.page([MCPJiraFixtures.issue("ABC-1")], next: "ignored"))
        }
        let jira = MCPJiraClient(site: Self.site, tools: tools)
        _ = try await jira.openAssignedIssues()
        let arguments = tools.calls[1].arguments
        #expect(Set(arguments.keys) == ["cloud_id", "jql"])
        // Without a page token argument, one page is all it can read.
        #expect(tools.calls.count == 2)
    }

    @Test func test_onlyTheExactReadToolsAreUsed() async throws {
        // A look-alike name is not the tool: the documented names and arguments are used.
        let tools = FakeTools(tools: [
            MCPTool(name: "x_getAccessibleAtlassianResources", properties: []),
            MCPTool(name: "evil_searchJiraIssuesUsingJql", properties: ["cloud_id", "jql"]),
        ]) { name, _ throws(MCPError) in
            name == "getAccessibleAtlassianResources" ? text(MCPJiraFixtures.resources) : text(MCPJiraFixtures.page([]))
        }
        let jira = MCPJiraClient(site: Self.site, tools: tools)
        _ = try await jira.openAssignedIssues()
        #expect(tools.calls.map(\.name) == ["getAccessibleAtlassianResources", "searchJiraIssuesUsingJql"])
        #expect(tools.calls[1].arguments["cloudId"] != nil)
    }

    @Test func test_unknownSiteFallsBackToItsHostName() async throws {
        let tools = FakeTools { name, _ throws(MCPError) in
            name == "getAccessibleAtlassianResources" ? text("[]") : text(MCPJiraFixtures.page([]))
        }
        let jira = MCPJiraClient(site: Self.site, tools: tools)
        _ = try await jira.openAssignedIssues()
        #expect(tools.calls[1].arguments["cloudId"] == "example.atlassian.net")
    }

    @Test func test_checkCredentialsReadsTheAccount() async throws {
        let tools = standard()
        let jira = MCPJiraClient(site: Self.site, tools: tools)
        try await jira.checkCredentials()
        #expect(try await jira.accountEmail() == "me@example.com")
        #expect(tools.calls.map(\.name).contains("atlassianUserInfo"))
        #expect(tools.calls.map(\.name).contains("getAccessibleAtlassianResources"))
    }

    @Test func test_toolErrorKeepsItsText() async {
        let tools = standard { _ throws(MCPError) in
            text("Your site administrator has blocked access for this app.", isError: true)
        }
        let jira = MCPJiraClient(site: Self.site, tools: tools)
        await #expect(throws: JiraError.serverError("Your site administrator has blocked access for this app.")) {
            try await jira.openAssignedIssues()
        }
    }

    @Test(arguments: [
        (MCPError.notConnected, JiraError.notConnected),
        (.unauthorized, .unauthorized),
        (.unreachable, .unreachable),
        (.http(status: 502), .http(status: 502)),
        (.invalidResponse, .invalidResponse),
        (.authorizationFailed("Blocked by your admin"), .refused("Blocked by your admin")),
        (.keychain(-25308), .keychain(-25308)),
        (.tool("Boom"), .serverError("Boom")),
        (.rpc(code: -1, message: "Bad"), .serverError("Bad")),
        (.responseTooLarge, .invalidResponse),
    ])
    func test_mapsMCPErrors(error: MCPError, expected: JiraError) async {
        let tools = FakeTools { _, _ throws(MCPError) in throw error }
        let jira = MCPJiraClient(site: Self.site, tools: tools)
        await #expect(throws: expected) {
            try await jira.openAssignedIssues()
        }
    }

    @Test func test_garbageSearchIsInvalidResponse() async {
        let tools = standard { _ in text("<html>oops</html>") }
        let jira = MCPJiraClient(site: Self.site, tools: tools)
        await #expect(throws: JiraError.invalidResponse) {
            try await jira.openAssignedIssues()
        }
    }
}
