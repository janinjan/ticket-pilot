import AppKit
import TicketPilotCore

/// The dialog of the guided setup that asks which Jira site to use.
extension Alerts {
    /// Asks which of the account's Jira sites to use; nil when cancelled.
    static func chooseSite(_ sites: [URL]) -> URL? {
        let alert = NSAlert()
        alert.messageText = "Choose your Jira site"
        alert.informativeText = "Your Atlassian account can open several Jira sites. TicketPilot reads your tickets on one."
        let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26), pullsDown: false)
        popUp.addItems(withTitles: sites.map { $0.host ?? $0.absoluteString })
        popUp.setAccessibilityLabel("Jira site")
        alert.accessoryView = popUp
        alert.addButton(withTitle: "Use this site")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn, sites.indices.contains(popUp.indexOfSelectedItem) else { return nil }
        return sites[popUp.indexOfSelectedItem]
    }
}
