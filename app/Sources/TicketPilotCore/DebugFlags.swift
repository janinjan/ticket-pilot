import Foundation

/// Debugging aids, all off in normal use, read from the environment at launch:
/// - `TICKET_PILOT_DEBUG_OPEN_PANEL=1`: the app opens its panel by itself and logs its frame to stderr.
/// - `TICKET_PILOT_DEBUG_NO_KEYCHAIN=1`: every Keychain read finds nothing and every write or delete is
///   skipped, so a debug build never touches (nor prompts for) the user's real sign-in.
/// - `TICKET_PILOT_DEBUG_FAKE_TICKETS=<n>`: Jira is replaced by `n` made-up tickets, plus a new one from the
///   second read (implies no Keychain); the tickets seen and the new ones are kept apart from the real ones.
public struct DebugFlags: Equatable, Sendable {
    public var opensPanel: Bool
    public var skipsKeychain: Bool
    public var fakeTicketCount: Int?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        opensPanel = environment["TICKET_PILOT_DEBUG_OPEN_PANEL"] == "1"
        fakeTicketCount = environment["TICKET_PILOT_DEBUG_FAKE_TICKETS"].flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil }
        skipsKeychain = environment["TICKET_PILOT_DEBUG_NO_KEYCHAIN"] == "1" || fakeTicketCount != nil
    }

    public static let current = DebugFlags()

    /// `count` made-up tickets, half ready to start and half in the backlog.
    public static func fakeIssues(count: Int) -> [JiraIssue] {
        (0..<count).map { index in
            JiraIssue(
                key: "FAKE-\(index + 1)",
                summary: "Made-up ticket number \(index + 1) for checking the panel layout",
                statusName: index.isMultiple(of: 2) ? "To Start" : "Backlog",
                statusCategory: .toDo
            )
        }
    }

    /// The made-up tickets of Jira's `read`-th read (from 1): from the second one, a new ticket joins them, to
    /// check the "New" section by hand.
    public static func fakeIssues(count: Int, read: Int) -> [JiraIssue] {
        let issues = fakeIssues(count: count)
        guard read >= 2 else { return issues }
        return issues + [JiraIssue(
            key: "FAKE-NEW",
            summary: "Made-up ticket assigned after the first read, for checking the New section",
            statusName: "To Start",
            statusCategory: .toDo
        )]
    }
}
