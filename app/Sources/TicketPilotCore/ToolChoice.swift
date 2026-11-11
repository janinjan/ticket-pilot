import Foundation

/// An app and what it opens: a worktree folder, or the Xcode project in it.
public struct EditorTarget: Equatable, Sendable {
    /// The name shown ("Open in Xcode").
    public var app: String
    public var path: String
    /// The exact `.app` to open, when known: the newest copy found, or the configured path.
    public var appPath: String?

    public init(app: String, path: String, appPath: String? = nil) {
        self.app = app
        self.path = path
        self.appPath = appPath
    }
}

/// The git client a finished run is reviewed in, and the editor a run is opened in.
public enum ToolChoice {
    /// Git clients picked without being told, in order of preference, by their `.app` name.
    public static let gitClients = ["GitHub Desktop", "Fork", "Tower", "Sourcetree", "GitKraken"]
    /// Editors for a `package.json` project, in order of preference.
    public static let webEditors = ["Visual Studio Code", "Cursor", "WebStorm"]
    /// Every app `editor` may pick by itself, to look for once.
    public static let knownEditors = ["Xcode", "Android Studio"] + webEditors

    /// The configured `git_client`, else the first installed of `gitClients`; nil when none is.
    public static func gitClient(configured: String?, installed: [String]) -> String? {
        if let name = configured?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        return gitClients.first(where: installed.contains)
    }

    /// The configured `repos[].editor`, else by the project type found in the worktree's root `entries`:
    /// an Xcode project or `Package.swift` → Xcode, a Gradle project → Android Studio, a `package.json` →
    /// the first installed of `webEditors`. Only an installed app is picked. Xcode opens the
    /// `.xcworkspace`, else the `.xcodeproj`, else the folder. `configured` may be an app name or an
    /// absolute `.app` path; `appPaths` gives the exact copy of each installed app (the newest one).
    public static func editor(
        configured: String?, worktree: String, entries: [String], installed: [String], appPaths: [String: String] = [:]
    ) -> EditorTarget? {
        let xcodeProject = entries.sorted().first { $0.hasSuffix(".xcworkspace") }
            ?? entries.sorted().first { $0.hasSuffix(".xcodeproj") }
        func target(_ app: String, appPath: String?) -> EditorTarget {
            let isXcode = app == "Xcode" || app.hasPrefix("Xcode_") || app.hasPrefix("Xcode-")
            let path = isXcode ? xcodeProject.map { (worktree as NSString).appendingPathComponent($0) } : nil
            return EditorTarget(app: app, path: path ?? worktree, appPath: appPath)
        }
        if let name = configured?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            if name.hasPrefix("/"), name.hasSuffix(".app") {
                return target(((name as NSString).lastPathComponent as NSString).deletingPathExtension, appPath: name)
            }
            return target(name, appPath: appPaths[name])
        }
        let app: String?
        if xcodeProject != nil || entries.contains("Package.swift") {
            app = "Xcode"
        } else if entries.contains(where: { ["settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts"].contains($0) }) {
            app = "Android Studio"
        } else if entries.contains("package.json") {
            app = webEditors.first(where: installed.contains)
        } else {
            app = nil
        }
        guard let app, installed.contains(app) else { return nil }
        return target(app, appPath: appPaths[app])
    }
}

/// One copy of an app found on disk.
public struct AppCandidate: Equatable, Sendable {
    public var path: String
    /// `CFBundleShortVersionString`, if the bundle has one.
    public var version: String?
    /// Named exactly like the app ("Xcode.app"), not a variant ("Xcode_27.app").
    public var isPlainName: Bool

    public init(path: String, version: String?, isPlainName: Bool) {
        self.path = path
        self.version = version
        self.isPlainName = isPlainName
    }

    /// The copy with the highest version, compared as numbers ("10.0" > "9.4.1", "27.1" > "27.0"); one
    /// without a version loses; a tie goes to the plain name, then to the path.
    public static func newest(_ candidates: [AppCandidate]) -> AppCandidate? {
        candidates.max { a, b in
            let order = compare(a.version, b.version)
            if order != .orderedSame { return order == .orderedAscending }
            if a.isPlainName != b.isPlainName { return !a.isPlainName }
            return a.path > b.path
        }
    }

    private static func compare(_ a: String?, _ b: String?) -> ComparisonResult {
        switch (a.map(numbers), b.map(numbers)) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        case let (x?, y?):
            for index in 0..<max(x.count, y.count) {
                let left = index < x.count ? x[index] : 0
                let right = index < y.count ? y[index] : 0
                if left != right { return left < right ? .orderedAscending : .orderedDescending }
            }
            return .orderedSame
        }
    }

    /// "27.1b2" reads as [27, 1]: each part's leading digits.
    private static func numbers(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
}

/// Finds apps in the application folders: "<name>.app", or a variant of it ("Xcode_27.1.app",
/// "Xcode-beta.app", "Android Studio Preview.app"), the newest copy when there are several.
public struct ApplicationFinder: Sendable {
    public var directories: [URL]

    public init(directories: [URL] = TerminalDetector.defaultDirectories) {
        self.directories = directories
    }

    public func installed(among names: [String]) -> [String] {
        names.filter { locate($0) != nil }
    }

    /// The exact path of each installed app among `names`.
    public func paths(among names: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: names.compactMap { name in locate(name).map { (name, $0) } })
    }

    /// The newest copy of `name`, by its `CFBundleShortVersionString`.
    public func locate(_ name: String) -> String? {
        var candidates: [AppCandidate] = []
        for directory in directories {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let base = String(entry.dropLast(4))
                let plain = base == name
                guard plain || ["_", "-", " "].contains(where: { base.hasPrefix(name + $0) }) else { continue }
                let path = directory.appendingPathComponent(entry).path
                let info = NSDictionary(contentsOfFile: (path as NSString).appendingPathComponent("Contents/Info.plist"))
                candidates.append(AppCandidate(
                    path: path, version: info?["CFBundleShortVersionString"] as? String, isPlainName: plain
                ))
            }
        }
        return AppCandidate.newest(candidates)?.path
    }
}

/// Opens a folder or a project with an app: `open -a <exact .app path> <path>` when the copy is known,
/// else by name (Xcode by its bundle id).
public struct ToolLauncher: Sendable {
    public var runner: ProcessRunning

    public init(runner: ProcessRunning) {
        self.runner = runner
    }

    public func open(_ target: EditorTarget) throws {
        let app = if let appPath = target.appPath {
            ["-a", appPath]
        } else if target.app == "Xcode" {
            ["-b", "com.apple.dt.Xcode"]
        } else {
            ["-a", target.app]
        }
        let result = try runner.run("/usr/bin/open", app + [target.path], currentDirectory: nil)
        guard result.status == 0 else {
            throw ToolLaunchError(app: target.app, message: result.error.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

public struct ToolLaunchError: Error, Equatable, CustomStringConvertible {
    public var app: String
    public var message: String

    public var description: String {
        message.isEmpty ? "\(app) did not open." : message
    }
}
