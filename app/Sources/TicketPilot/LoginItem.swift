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
    /// The marker holds the bundle path the registration was made for, written only once it
    /// succeeded, so a failure is retried. When the app runs from another path (it moved to
    /// /Applications), an enabled registration is renewed so the login item follows the app.
    static func registerOnce(marker: URL, bundlePath: String = Bundle.main.bundlePath) {
        let recorded = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
        let markerExists = FileManager.default.fileExists(atPath: marker.path)
        guard !markerExists || recorded != bundlePath else { return }
        do {
            if markerExists {
                if isEnabled {
                    try? SMAppService.mainApp.unregister()
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.register()
            }
            try FileManager.default.createDirectory(
                at: marker.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(bundlePath.utf8).write(to: marker)
        } catch {
            return
        }
    }
}
