import Foundation

/// The tickets newly assigned to the user that the panel has not shown yet: listed first, under "New", until
/// the panel closes after showing them. Fed with the tickets a Jira poll notifies (`TicketTracker`), so the
/// first poll and the tickets already seen never count; kept next to `seen.json`, which means "notified".
public struct NewTickets: Equatable, Sendable {
    public private(set) var keys: Set<String>
    /// The new tickets on screen since the panel opened: they leave when it closes.
    private var shown: Set<String> = []
    private var panelIsOpen = false

    public init(keys: Set<String> = []) {
        self.keys = keys
    }

    /// Some new ticket has not been on screen yet: the menu bar icon shows a dot.
    public var hasUnshown: Bool {
        !keys.isSubset(of: shown)
    }

    /// Tickets notified by a poll; with the panel open, they are on screen at once.
    public mutating func add(_ newKeys: some Sequence<String>) {
        keys.formUnion(newKeys)
        if panelIsOpen { shown = keys }
    }

    /// Drops the tickets the list would not show (a run, a finished status, no longer assigned): they are
    /// no longer new, even if listed again later. `nil` before Jira first answered keeps every ticket, as
    /// the listed tickets are not known yet.
    public mutating func keepOnly(_ listed: Set<String>?) {
        guard let listed else { return }
        keys.formIntersection(listed)
        shown.formIntersection(listed)
    }

    public mutating func panelOpened() {
        panelIsOpen = true
        shown = keys
    }

    /// The tickets shown while the panel was open are no longer new.
    public mutating func panelClosed() {
        keys.subtract(shown)
        shown = []
        panelIsOpen = false
    }

    /// The saved tickets; none when the file is absent or unreadable.
    public static func load(from store: SeenStore) -> NewTickets {
        NewTickets(keys: store.load() ?? [])
    }

    public func save(to store: SeenStore) throws {
        try store.save(keys)
    }
}
