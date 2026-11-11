import Foundation

/// The installed ticket-pilot plugin compared with the copy the app carries.
public enum PluginState: Equatable, Sendable {
    /// Not installed in Claude Code.
    case missing
    /// Installed, older than the copy the app carries.
    case outdated(installed: String, bundled: String)
    /// Installed, the same version as the copy the app carries.
    case current
    /// Installed, newer than the copy the app carries (a newer release, a local checkout): left alone.
    case newerThanBundled
    /// Installed, but a version could not be read (or the app carries no copy): left alone.
    case unknown

    /// True when the app offers to install or update the plugin.
    public var needsInstall: Bool {
        switch self {
        case .missing, .outdated: true
        case .current, .newerThanBundled, .unknown: false
        }
    }

    /// Compares two versions by their numeric components ("0.10" is newer than "0.9"); a leading "v" and a
    /// "-pre-release" or "+build" suffix are ignored, missing components count as 0.
    public static func compare(installed: String?, bundled: String?) -> PluginState {
        guard let installed else { return .missing }
        guard let bundled, let have = components(installed), let carried = components(bundled) else {
            return .unknown
        }
        let count = max(have.count, carried.count)
        let lhs = have + Array(repeating: 0, count: count - have.count)
        let rhs = carried + Array(repeating: 0, count: count - carried.count)
        if lhs == rhs { return .current }
        return lhs.lexicographicallyPrecedes(rhs) ? .outdated(installed: installed, bundled: bundled) : .newerThanBundled
    }

    private static func components(_ version: String) -> [Int]? {
        var core = Substring(version.trimmingCharacters(in: .whitespaces))
        if core.first == "v" || core.first == "V" { core = core.dropFirst() }
        if let suffix = core.firstIndex(where: { $0 == "-" || $0 == "+" }) { core = core[..<suffix] }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        return numbers
    }
}
