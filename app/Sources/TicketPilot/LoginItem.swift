import Foundation
import ServiceManagement

/// Open at login, through `SMAppService.mainApp`. Only usable from a `.app` bundle.
@MainActor
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Turns Open at login on once, on the first launch; the user may turn it off afterwards.
    /// The marker is only written once the registration succeeded, so a failure is retried.
    static func registerOnce(marker: URL) {
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        do {
            try SMAppService.mainApp.register()
            try FileManager.default.createDirectory(
                at: marker.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data().write(to: marker)
        } catch {
            return
        }
    }
}
