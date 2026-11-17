import Foundation

/// The line under the panel that tells what the refresh button reads and when it last did:
/// "Tickets updated 3 min ago", or "Updating tickets…" while it reads them.
public enum TicketsFreshness {
    public static func text(lastUpdate: Date?, refreshing: Bool, now: Date) -> String? {
        if refreshing { return "Updating tickets…" }
        guard let lastUpdate else { return nil }
        let minutes = Int(now.timeIntervalSince(lastUpdate) / 60)
        switch minutes {
        case ..<1: return "Tickets updated just now"
        case ..<60: return "Tickets updated \(minutes) min ago"
        default: return "Tickets updated \(minutes / 60) h ago"
        }
    }

    /// Opening the panel reads Jira again when the last read is more than a minute old, or never happened.
    public static func needsRead(lastUpdate: Date?, now: Date) -> Bool {
        guard let lastUpdate else { return true }
        return now.timeIntervalSince(lastUpdate) > 60
    }
}
