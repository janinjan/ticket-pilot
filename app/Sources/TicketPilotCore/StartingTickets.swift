import Foundation

/// Tickets whose Start was clicked and whose run has not appeared yet: their button reads "Starting…".
/// A start is settled by its run (the skill writes it at step 1), cleared by a failure, or given up after
/// `timeout`, so a session that never began never leaves the button stuck.
public struct StartingTickets: Equatable, Sendable {
    public static let timeout: TimeInterval = 180

    private var since: [String: Date] = [:]

    public init() {}

    public func contains(_ key: String) -> Bool {
        since[key] != nil
    }

    public mutating func mark(_ key: String, at date: Date) {
        since[key] = date
    }

    public mutating func clear(_ key: String) {
        since[key] = nil
    }

    /// Drops the tickets that now have a run, and those started `timeout` ago or more.
    public mutating func settle(runs: [Run], now: Date) {
        let withRun = Set(runs.map(\.key))
        since = since.filter { key, date in
            !withRun.contains(key) && now.timeIntervalSince(date) < Self.timeout
        }
    }
}
