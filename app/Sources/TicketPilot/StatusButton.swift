import AppKit
import TicketPilotCore

/// The menu bar item's button, which `MenuBarExtra` does not expose: found in the status bar window to
/// give it a tooltip and a VoiceOver label and value (the icon is a rendered image).
@MainActor
enum StatusButton {
    static func update(_ icon: MenuBarIcon) {
        guard let button = find() else { return }
        button.toolTip = "TicketPilot"
        button.setAccessibilityLabel("TicketPilot")
        button.setAccessibilityValue(icon.accessibilityValue)
    }

    private static func find() -> NSStatusBarButton? {
        for window in NSApp.windows where String(describing: type(of: window)).contains("StatusBar") {
            if let button = window.contentView.flatMap(search) { return button }
        }
        return nil
    }

    private static func search(_ view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = search(subview) { return button }
        }
        return nil
    }
}
