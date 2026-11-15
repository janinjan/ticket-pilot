import AppKit
import TicketPilotCore

/// Modal alerts. The app is brought to the front first, as a menu bar app is never active.
@MainActor
enum Alerts {
    static func show(_ text: AlertText) {
        let alert = NSAlert()
        alert.messageText = text.title
        alert.informativeText = text.message
        NSApp.activate()
        alert.runModal()
    }

    /// Asks before doing what `text` describes; true when the user chose `button`.
    static func confirm(_ text: AlertText, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = text.title
        alert.informativeText = text.message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Lists what releasing will delete; true when the user chose Delete.
    static func confirmRelease(_ run: Run, plan: ReleasePlan) -> Bool {
        let alert = NSAlert()
        alert.messageText = plan.question
        alert.informativeText = "This deletes:\n" + plan.lines.joined(separator: "\n")
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}
