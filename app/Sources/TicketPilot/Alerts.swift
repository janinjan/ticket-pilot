import AppKit
import TicketPilotCore

/// Modal alerts. The app is brought to the front first, as a menu bar app is never active.
@MainActor
enum Alerts {
    private static let atlassianTokensURL = URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!

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

    /// Asks for the Jira API token; nil when cancelled or empty. The token is only returned, never kept.
    static func askJiraToken(site: String, email: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Jira API token"
        alert.informativeText = "Paste the API token for \(email) on \(site). It is stored in your Keychain."
        let field = PastableSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Create a token on Atlassian")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return field.stringValue
        case .alertThirdButtonReturn:
            // The alert closes rather than reopens: reopening would cover the browser that was just
            // opened. Connect Jira… in the panel (or Set Jira token… in Settings) brings it back.
            NSWorkspace.shared.open(atlassianTokensURL)
            return nil
        default:
            return nil
        }
    }
}

/// A menu bar app has no Edit menu, so the standard key equivalents never reach a text field.
private final class PastableSecureTextField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers
        else { return super.performKeyEquivalent(with: event) }
        let action: Selector? = switch key {
        case "v": #selector(NSText.paste(_:))
        case "a": #selector(NSText.selectAll(_:))
        case "x": #selector(NSText.cut(_:))
        case "c": #selector(NSText.copy(_:))
        case "z": Selector(("undo:"))
        default: nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}
