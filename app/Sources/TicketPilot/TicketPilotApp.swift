import AppKit
import Observation
import SwiftUI

@main
struct TicketPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: delegate.model)
        } label: {
            MenuBarLabel(icon: delegate.model.icon)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app: no Dock icon, even when run outside its bundle (`LSUIElement`).
        NSApp.setActivationPolicy(.accessory)
        model.start()
        // The status item exists once the first scene update ran.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.trackStatusButton()
            DebugPanel.openIfAsked()
        }
    }

    /// Keeps the status button's tooltip and VoiceOver value in step with the icon.
    private func trackStatusButton() {
        let icon = withObservationTracking {
            model.icon
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackStatusButton() }
        }
        StatusButton.update(icon)
    }
}
