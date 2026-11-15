import Foundation

public enum RepoDetectionError: Error, Equatable {
    case notAGitRepository
}

/// What the app proposes for a folder the user picked, before they confirm it.
public struct RepoProposal: Equatable, Sendable {
    /// `ios`, `android` or `web` from the project type, else the folder name made valid.
    public var name: String
    public var path: String
    /// Nil when no main branch was found: the user enters it.
    public var mainBranch: String?
    /// `gerrit` or `github`; nil when the `origin` remote tells neither: the user picks.
    public var review: String?

    public init(name: String, path: String, mainBranch: String?, review: String?) {
        self.name = name
        self.path = path
        self.mainBranch = mainBranch
        self.review = review
    }

    /// The checkout's folder name, shown next to the proposed name.
    public var folderName: String { URL(fileURLWithPath: path).lastPathComponent }

    /// An iOS, Android or web checkout (see `RepoDetector.defaultTicks`).
    public var isPlatform: Bool { ["ios", "android", "web"].contains(name) }

    /// The config entry for the confirmed values, with the match rules (how its tickets are recognised:
    /// title prefix, label, component) of the detected platform, whatever its name; else of `name`.
    public func entry(name: String, mainBranch: String, review: String?) -> RepoEntry {
        let rules: (prefixes: [String], tag: String) = switch isPlatform ? self.name : name {
        case "ios": (["[iOS]"], "iOS")
        case "android": (["[Android]", "[AND]"], "Android")
        case "web": (["[Web]"], "Web")
        default: (["[\(name)]"], name)
        }
        return RepoEntry(
            name: name, path: path, mainBranch: mainBranch, review: review,
            titlePrefixes: rules.prefixes, labels: [rules.tag], components: [rules.tag]
        )
    }
}

/// Reads a checkout to propose its config entry: platform, main branch, review kind.
public enum RepoDetector {
    private static let git = "/usr/bin/git"
    private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    public static func detect(folder: URL, runner: ProcessRunning) throws(RepoDetectionError) -> RepoProposal {
        func run(_ arguments: [String]) -> String? {
            guard let result = try? runner.run(git, ["-C", folder.path] + arguments, currentDirectory: nil),
                  result.status == 0
            else { return nil }
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return output.isEmpty ? nil : output
        }
        // The main checkout's root, as git spells it: the skill finds a repo by it, whether the user
        // picked a subfolder or a linked worktree.
        guard run(["rev-parse", "--show-toplevel"]) != nil,
              let common = run(["rev-parse", "--path-format=absolute", "--git-common-dir"])
        else { throw .notAGitRepository }
        let root = URL(fileURLWithPath: common).deletingLastPathComponent()
        return RepoProposal(
            name: platform(of: root) ?? validName(from: root.lastPathComponent),
            path: root.path,
            mainBranch: mainBranch(run),
            review: run(["remote", "get-url", "origin"]).flatMap(review(ofRemote:))
        )
    }

    /// The main checkouts right inside `folder` (hidden folders and linked worktrees left out), or `folder`
    /// alone when it is one; without those whose root is in `excluding` (the repos already added). By folder
    /// name.
    public static func scan(folder: URL, runner: ProcessRunning, excluding: [String]) -> [RepoProposal] {
        func resolved(_ path: String) -> String {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
        }
        let added = Set(excluding.map(resolved))
        func isMainCheckout(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
        let candidates: [URL] = if isMainCheckout(folder) {
            [folder]
        } else {
            ((try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []).filter(isMainCheckout)
        }
        return candidates
            .compactMap { try? detect(folder: $0, runner: runner) }
            .filter { !added.contains(resolved($0.path)) }
            .sorted { $0.folderName.localizedStandardCompare($1.folderName) == .orderedAscending }
    }

    /// Which of `proposals` start ticked: an iOS, Android or web checkout, when it is the only one found
    /// for its platform and the config has none yet (`existingPlatforms`, see `RepoName.platform`).
    /// Otherwise picking is the user's.
    public static func defaultTicks(_ proposals: [RepoProposal], existingPlatforms: Set<String>) -> [Bool] {
        proposals.map { proposal in
            proposal.isPlatform && !existingPlatforms.contains(proposal.name)
                && proposals.filter { $0.name == proposal.name }.count == 1
        }
    }

    /// The names of the ticked checkouts, in order: the platform's (`ios`, `android`, `web`) for the
    /// first one, the folder's for the others, numbered (`-2`, `-3`…) when still taken.
    public static func names(for ticked: [RepoProposal], existing: [String]) -> [String] {
        var taken = Set(existing)
        return ticked.map { proposal in
            var name = [proposal.name, validName(from: proposal.folderName)].first { !taken.contains($0) }
                ?? validName(from: proposal.folderName)
            if taken.contains(name) {
                let base = name
                var number = 2
                while taken.contains("\(base)-\(number)") { number += 1 }
                name = "\(base)-\(number)"
            }
            taken.insert(name)
            return name
        }
    }

    private static func platform(of folder: URL) -> String? {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        if entries.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") || $0 == "Package.swift" }) {
            return "ios"
        }
        let gradle = ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]
        if entries.contains(where: gradle.contains) { return "android" }
        if entries.contains("package.json") { return "web" }
        return nil
    }

    private static func validName(from folderName: String) -> String {
        String(String.UnicodeScalarView(folderName.replacingOccurrences(of: " ", with: "-").unicodeScalars.filter(allowed.contains)))
    }

    /// `origin/HEAD`, else `main` then `master` when a local or `origin` branch has that name.
    private static func mainBranch(_ run: ([String]) -> String?) -> String? {
        if let head = run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]) {
            return head.hasPrefix("origin/") ? String(head.dropFirst("origin/".count)) : head
        }
        return ["main", "master"].first { name in
            ["refs/heads/\(name)", "refs/remotes/origin/\(name)"].contains { run(["rev-parse", "--verify", "--quiet", $0]) != nil }
        }
    }

    /// `gerrit` for Gerrit's SSH port, its authenticated HTTP path (`/a/`) or a host named after it
    /// (`gerrit…`, `review.…`); `github` for GitHub and GitHub Enterprise (`*.ghe.com`); else nil.
    private static func review(ofRemote url: String) -> String? {
        let lowered = url.lowercased()
        if lowered.contains(":29418") { return "gerrit" }
        let parsed = lowered.contains("://") ? URL(string: lowered) : nil
        let host: String = if let host = parsed?.host {
            host
        } else {
            // scp-like syntax: user@host:path
            String(lowered.split(separator: "@").last?.split(separator: ":").first ?? "")
        }
        if host.contains("github") || host.hasSuffix(".ghe.com") { return "github" }
        if host.contains("gerrit") || host.hasPrefix("review.") || parsed?.path.hasPrefix("/a/") == true { return "gerrit" }
        return nil
    }
}
