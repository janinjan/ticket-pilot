import Foundation

public enum JiraError: Error, Equatable {
    case unauthorized
    case unreachable
    case http(status: Int)
    case invalidResponse
    /// No Atlassian sign-in is stored (Atlassian MCP only).
    case notConnected
    /// The Atlassian MCP server refused the sign-in with this explanation (a 403, an administrator block,
    /// a consent not given).
    case refused(String)
    /// The Atlassian MCP server failed with this explanation (a tool error, a protocol error).
    case serverError(String)
    /// The Keychain refused to give the stored Atlassian sign-in.
    case keychain(OSStatus)
}

public protocol JiraSearching: Sendable {
    func openAssignedIssues() async throws(JiraError) -> [JiraIssue]
    func statusCategories(of keys: [String]) async throws(JiraError) -> [String: JiraIssue.StatusCategory]
    func checkCredentials() async throws(JiraError)
}
