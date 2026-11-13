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
        alert.messageText = "Remove the worktree of \(run.key) · \(run.repo)?"
        alert.informativeText = "This deletes:\n" + plan.lines.joined(separator: "\n")
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Asks for the Jira API token, explaining how to get one; nil when cancelled. The token is only
    /// returned, never kept. "Create a token" opens the Atlassian page and keeps the dialog open, so the
    /// token can be pasted when the user comes back.
    static func askJiraToken(site: String, email: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Connect Jira"
        alert.informativeText = """
        TicketPilot needs an API token to read your tickets on \(site) as \(email).

        1. Click Create a token — Atlassian opens in your browser.
        2. Create a token, then copy it.
        3. Paste it below and click Save.
        """
        let field = PastableSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Paste your API token"
        field.setAccessibilityLabel("Jira API token")
        let note = NSTextField(labelWithString: "Stored only in your Mac's Keychain.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [field, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 48)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        let create = alert.addButton(withTitle: "Create a token")
        let opener = URLOpener(url: atlassianTokensURL)
        create.target = opener
        create.action = #selector(URLOpener.open)
        create.setAccessibilityHelp("Opens the Atlassian page where API tokens are made")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = field
        NSApp.activate()
        let response = withExtendedLifetime(opener) { alert.runModal() }
        return response == .alertFirstButtonReturn ? field.stringValue : nil
    }
}

/// Opens a URL from a button without closing the alert it belongs to.
@MainActor
private final class URLOpener: NSObject {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    @objc func open() {
        NSWorkspace.shared.open(url)
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
