import AppKit
import SwiftUI
import TicketPilotCore

/// The window that hosts `RepoPickerView`, one at a time.
@MainActor
final class RepoPickerWindow {
    private var window: NSWindow?

    func show(
        issue: JiraIssue, choices: [RepoChoice], health: [HealthCheck], onStart: @escaping ([RepoChoice]) -> Void
    ) {
        close()
        let view = RepoPickerView(
            issue: issue,
            choices: choices,
            initialSelection: StartRoute.initialSelection(choices, health: health),
            blockReason: { health.startBlocker(repo: $0)?.detail },
            onStart: onStart,
            onCancel: { [weak self] in self?.close() }
        )
        let window = ClosableWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Start \(issue.key)"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
        window = nil
    }
}
