import Foundation

/// Keeps the Mac from idle-sleeping while `SleepPolicy.keepsMacAwake` holds.
@MainActor
final class SleepGuard {
    private var activity: NSObjectProtocol?

    func update(anyRunning: Bool) {
        if anyRunning, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .idleSystemSleepDisabled,
                reason: "A ticket-pilot run is in progress"
            )
        } else if !anyRunning, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
