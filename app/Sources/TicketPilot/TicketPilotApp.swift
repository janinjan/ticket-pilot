import AppKit
import SwiftUI

@main
struct TicketPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model)
        } label: {
            MenuBarLabel(icon: delegate.model.icon)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app: no Dock icon, even when run outside its bundle (`LSUIElement`).
        NSApp.setActivationPolicy(.accessory)
        model.start()
    }
}
