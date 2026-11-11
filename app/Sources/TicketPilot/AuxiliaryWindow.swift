import AppKit
import SwiftUI

/// A small window of the app (Settings, About): made once, brought to the front when asked again.
@MainActor
final class AuxiliaryWindow {
    private var window: NSWindow?

    func show<Content: View>(title: String, resizable: Bool = false, content: () -> Content) {
        if window == nil {
            let controller = NSHostingController(rootView: content())
            controller.sizingOptions = [.preferredContentSize]
            let window = ClosableWindow(contentViewController: controller)
            window.title = title
            window.styleMask = resizable ? [.titled, .closable, .resizable] : [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

/// A menu bar app has no File menu, so ⌘W would not reach the window: it is handled here.
final class ClosableWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
