import Foundation

/// Reads the run files written by the plugin. Never writes.
public struct RunStore: Sendable {
    public var directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// All readable runs, most recently updated first. Temp and corrupt files are skipped.
    public func loadAll() -> [Run] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        let decoder = JSONDecoder.runDecoder
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Run.self, from: $0) }
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}
