import AppKit
import TicketPilotCore

/// A debugging aid, off in normal use (see `DebugFlags`). Launched with `TICKET_PILOT_DEBUG_OPEN_PANEL=1`,
/// the app opens its own panel (from inside the app, never a click in the user's UI), closes it after 8 s
/// and opens it again, and logs to stderr each frame of the panel's window against the status item's
/// and the top of the screen's visible frame. Launch it with a throwaway `TICKET_PILOT_HOME` and
/// `TICKET_PILOT_CONFIG`, and `TICKET_PILOT_DEBUG_NO_KEYCHAIN=1` or `TICKET_PILOT_DEBUG_FAKE_TICKETS=<n>`:
///
///     TICKET_PILOT_HOME=/tmp/tp TICKET_PILOT_CONFIG=/tmp/tp/config.json TICKET_PILOT_DEBUG_OPEN_PANEL=1 \
///         TICKET_PILOT_DEBUG_FAKE_TICKETS=20 app/.build/debug/TicketPilot
@MainActor
enum DebugPanel {
    static func openIfAsked() {
        guard DebugFlags.current.opensPanel else { return }
        Task { @MainActor in
            StatusButton.openPanel()
            try? await Task.sleep(for: .milliseconds(50))
            observePanel()
            for second in 1...8 {
                try? await Task.sleep(for: .seconds(1))
                log("t+\(second)s")
            }
            StatusButton.closePanel()
            log("closed")
            try? await Task.sleep(for: .seconds(1))
            StatusButton.openPanel()
            try? await Task.sleep(for: .milliseconds(50))
            log("opened again")
        }
    }

    /// Logs the panel's frame, in debug mode only.
    static func log(_ moment: String) {
        guard DebugFlags.current.opensPanel else { return }
        let item = StatusButton.statusItemFrame().map { "\($0)" } ?? "nil"
        let visibleTop = NSScreen.main.map { "\($0.visibleFrame.maxY)" } ?? "nil"
        for window in panels {
            FileHandle.standardError.write(Data((
                "[panel] \(moment) visible=\(window.isVisible) frame=\(window.frame) top=\(window.frame.maxY) "
                    + "minSize=\(window.contentMinSize) statusItem=\(item) visibleMaxY=\(visibleTop)\n"
            ).utf8))
        }
    }

    private static var panels: [NSWindow] {
        NSApp.windows.filter { !String(describing: type(of: $0)).contains("StatusBar") }
    }

    private static func observePanel() {
        log("opened")
        for window in panels {
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
                let moment = name == NSWindow.didResizeNotification ? "resized" : "moved"
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { log(moment) }
                }
            }
        }
    }
}

/// Jira replaced by made-up tickets, under `TICKET_PILOT_DEBUG_FAKE_TICKETS` only.
struct DebugJira: JiraSearching {
    let count: Int

    func openAssignedIssues() async throws(JiraError) -> [JiraIssue] {
        DebugFlags.fakeIssues(count: count)
    }

    func statusCategories(of keys: [String]) async throws(JiraError) -> [String: JiraIssue.StatusCategory] {
        [:]
    }

    func checkCredentials() async throws(JiraError) {}
}
