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

    /// Opens the panel as a click on the status item does (`MenuBarExtra` gives its button no action: it
    /// shows the panel when the status item's session begins); for `DebugPanel` only.
    static func openPanel() {
        guard let item = find()?.value(forKey: "_statusItem") as? NSObject else { return }
        let request = NSSelectorFromString("_requestExpandedInterfaceSession")
        if item.responds(to: request) { item.perform(request) }
    }

    /// Closes the panel as a click elsewhere does, by ending that session; for `DebugPanel` only.
    static func closePanel() {
        guard let item = find()?.value(forKey: "_statusItem") as? NSObject,
              let ivar = class_getInstanceVariable(NSStatusItem.self, "_expandedInterfaceSession"),
              let session = object_getIvar(item, ivar) as? NSObject
        else { return }
        let cancel = NSSelectorFromString("cancel")
        if session.responds(to: cancel) { session.perform(cancel) }
    }

    /// The status item's frame on screen; for `DebugPanel` only.
    static func statusItemFrame() -> NSRect? {
        find()?.window?.frame
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
