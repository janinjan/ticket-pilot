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

    /// Lists what releasing will delete; true when the user chose Delete.
    static func confirmRelease(_ run: Run, plan: ReleasePlan) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Release \(run.key) · \(run.repo)?"
        alert.informativeText = "This deletes:\n" + plan.lines.joined(separator: "\n")
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}
