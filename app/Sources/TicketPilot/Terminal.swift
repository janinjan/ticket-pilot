import Foundation
import TicketPilotCore

/// Runs `TerminalLauncher` off the main thread (`open` blocks) and reports a failure in an alert.
struct Terminal: Sendable {
    let launcher: TerminalLauncher

    func open(_ command: String) {
        perform { try launcher.open(command: command) }
    }

    func activate() {
        perform { try launcher.activate() }
    }

    private func perform(_ action: @escaping @Sendable () throws -> Void) {
        Task.detached {
            do {
                try action()
            } catch {
                await Alerts.show(AlertText(title: "The terminal did not open", message: "\(error)"))
            }
        }
    }
}
