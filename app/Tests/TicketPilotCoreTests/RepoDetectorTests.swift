import Foundation
import Testing
@testable import TicketPilotCore

@Suite(.timeLimit(.minutes(1))) struct RepoDetectorTests {
    /// A git checkout in a fresh temporary folder named `name`, with `files` at its root.
    private func makeRepo(_ name: String = "repo", files: [String] = [], branch: String = "main") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(name).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in files {
            if file.hasSuffix(".xcodeproj") {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(file), withIntermediateDirectories: true)
            } else {
                try Data("{}".utf8).write(to: root.appendingPathComponent(file))
            }
        }
        try git(["init", "-q", "-b", branch], in: root)
        try git(["commit", "-q", "--allow-empty", "-m", "initial"], in: root)
        return root
    }

    @discardableResult
    private func git(_ arguments: [String], in folder: URL) throws -> ProcessResult {
        let result = try SystemProcessRunner().run(
            "/usr/bin/git", ["-c", "user.name=Test", "-c", "user.email=test@example.com"] + arguments, currentDirectory: folder
        )
        try #require(result.status == 0, "git \(arguments) failed: \(result.error)")
        return result
    }

    /// `origin` at `url`, with `origin/HEAD` pointing to `head` when given.
    private func addOrigin(_ url: String, head: String? = nil, in folder: URL) throws {
        try git(["remote", "add", "origin", url], in: folder)
        guard let head else { return }
        try git(["update-ref", "refs/remotes/origin/\(head)", "HEAD"], in: folder)
        try git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/\(head)"], in: folder)
    }

    private func detect(_ folder: URL) throws -> RepoProposal {
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        return try RepoDetector.detect(folder: folder, runner: SystemProcessRunner())
    }

    @Test func test_detectsAnIOSGerritRepo() throws {
        let folder = try makeRepo(files: ["App.xcodeproj"])
        try addOrigin("ssh://me@review.example.com:29418/ios/app", head: "master", in: folder)
        let root = try topLevel(folder)
        let proposal = try detect(folder)
        #expect(proposal.name == "ios")
        #expect(proposal.path == root)
        #expect(proposal.review == "gerrit")
        #expect(proposal.mainBranch == "master")
    }

    @Test func test_detectsAWebGitHubEnterpriseRepo() throws {
        let folder = try makeRepo(files: ["package.json"])
        try addOrigin("git@acme.ghe.com:org/web.git", head: "main", in: folder)
        let proposal = try detect(folder)
        #expect(proposal.name == "web")
        #expect(proposal.review == "github")
    }

    @Test func test_detectsAnAndroidGitHubRepo() throws {
        let folder = try makeRepo(files: ["settings.gradle.kts"])
        try addOrigin("https://github.com/org/android.git", in: folder)
        let proposal = try detect(folder)
        #expect(proposal.name == "android")
        #expect(proposal.review == "github")
    }

    /// Gerrit over HTTPS (`/a/` is its authenticated path), over SSH without its port, or on a host named
    /// after it.
    @Test(arguments: [
        "https://me@review.example.ci/a/org/app-config",
        "ssh://review.example.ci/tools/ci-jobs",
        "https://gerrit.googlesource.com/gerrit-mcp-server",
    ])
    func test_detectsGerritWithoutItsSSHPort(remote: String) throws {
        let folder = try makeRepo()
        try addOrigin(remote, in: folder)
        #expect(try detect(folder).review == "gerrit")
    }

    @Test func test_unknownRemoteAndNoOriginHEADLeaveTheChoice() throws {
        let folder = try makeRepo()
        let proposal = try detect(folder)
        #expect(proposal.review == nil)
        #expect(proposal.mainBranch == "main")
    }

    @Test func test_noMainBranchFound() throws {
        let folder = try makeRepo(branch: "trunk")
        #expect(try detect(folder).mainBranch == nil)
    }

    @Test func test_folderNameMadeValid() throws {
        let folder = try makeRepo("My App!")
        #expect(try detect(folder).name == "My-App")
    }

    /// git's own spelling of the checkout's root (`/private/var/…` for a temporary folder), as the skill
    /// compares it.
    private func topLevel(_ folder: URL) throws -> String {
        try git(["rev-parse", "--show-toplevel"], in: folder).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The skill finds a repo by its main checkout's root: a subfolder or a linked worktree is written as it.
    @Test func test_thePathIsTheMainCheckoutRoot() throws {
        let folder = try makeRepo(files: ["package.json"])
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let root = try topLevel(folder)
        let sub = folder.appendingPathComponent("ios")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        #expect(try RepoDetector.detect(folder: sub, runner: SystemProcessRunner()).path == root)
        let linked = folder.deletingLastPathComponent().appendingPathComponent("wt")
        try git(["worktree", "add", "-q", "-b", "other", linked.path], in: folder)
        #expect(try RepoDetector.detect(folder: linked, runner: SystemProcessRunner()).path == root)
    }

    @Test func test_notAGitRepositoryIsRefused() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: RepoDetectionError.notAGitRepository) {
            try RepoDetector.detect(folder: folder, runner: SystemProcessRunner())
        }
    }

    /// The rules follow the detected platform, not the name: a second web checkout named after its folder
    /// still recognises the web tickets.
    @Test func test_matchRulesFollowThePlatform() {
        func entry(_ platform: String, named name: String) -> RepoEntry {
            RepoProposal(name: platform, path: "/r", mainBranch: nil, review: nil).entry(name: name, mainBranch: "main", review: nil)
        }
        #expect(entry("ios", named: "ios") == RepoEntry(
            name: "ios", path: "/r", mainBranch: "main", review: nil,
            titlePrefixes: ["[iOS]"], labels: ["iOS"], components: ["iOS"]
        ))
        #expect(entry("web", named: "web-app").titlePrefixes == ["[Web]"])
        #expect(entry("android", named: "kmp").titlePrefixes == ["[Android]", "[AND]"])
        let other = entry("backoffice", named: "backoffice-2")
        #expect(other.titlePrefixes == ["[backoffice-2]"])
        #expect(other.components == ["backoffice-2"])
    }

    // MARK: - Scan

    /// A folder holding several checkouts, like ~/Developer.
    private func makeParent() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return parent
    }

    private func makeRepo(_ name: String, in parent: URL, files: [String] = []) throws -> URL {
        let folder = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files { try Data("{}".utf8).write(to: folder.appendingPathComponent(file)) }
        try git(["init", "-q", "-b", "main"], in: folder)
        try git(["commit", "-q", "--allow-empty", "-m", "initial"], in: folder)
        return folder
    }

    @Test func test_scanListsTheCheckoutsOfAFolder() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let web = try makeRepo("web-app", in: parent, files: ["package.json"])
        _ = try makeRepo("Backend", in: parent)
        try FileManager.default.createDirectory(at: parent.appendingPathComponent("notes"), withIntermediateDirectories: true)
        _ = try makeRepo(".hidden", in: parent)
        try git(["worktree", "add", "-q", "-b", "other", parent.appendingPathComponent("web-wt").path], in: web)
        let found = RepoDetector.scan(folder: parent, runner: SystemProcessRunner(), excluding: [])
        #expect(found.map(\.folderName) == ["Backend", "web-app"])
        #expect(found.map(\.name) == ["Backend", "web"])
        #expect(found.map(\.isPlatform) == [false, true])
    }

    @Test func test_scanLeavesOutTheReposAlreadyAdded() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let app = try makeRepo("app", in: parent)
        _ = try makeRepo("web", in: parent, files: ["package.json"])
        let found = RepoDetector.scan(folder: parent, runner: SystemProcessRunner(), excluding: [app.path])
        #expect(found.map(\.folderName) == ["web"])
    }

    @Test func test_scanOfACheckoutListsItAlone() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let app = try makeRepo("app", in: parent)
        #expect(RepoDetector.scan(folder: app, runner: SystemProcessRunner(), excluding: []).map(\.folderName) == ["app"])
    }

    /// A platform is ticked only when one checkout has it: among several, the user picks.
    @Test func test_onlyAPlatformFoundOnceIsTicked() {
        func proposal(_ name: String) -> RepoProposal { RepoProposal(name: name, path: "/r/\(name)", mainBranch: "main", review: nil) }
        let found = ["android", "ios", "web", "ios", "go", "web"].map(proposal)
        #expect(RepoDetector.defaultTicks(found, existingPlatforms: []) == [true, false, false, false, false, false])
    }

    /// Adding more repos later ticks nothing for a platform the config already has.
    @Test func test_aPlatformAlreadyInTheConfigIsNotTicked() {
        func proposal(_ name: String) -> RepoProposal { RepoProposal(name: name, path: "/r/\(name)", mainBranch: "main", review: nil) }
        let found = ["android", "ios", "web"].map(proposal)
        #expect(RepoDetector.defaultTicks(found, existingPlatforms: ["ios", "android", "web"]) == [false, false, false])
        #expect(RepoDetector.defaultTicks(found, existingPlatforms: ["ios"]) == [true, false, true])
    }

    /// The first ticked checkout of a platform takes its name; the others keep their folder's.
    @Test func test_namesAreChosenWithoutConflicts() {
        func proposal(_ name: String, _ folder: String) -> RepoProposal {
            RepoProposal(name: name, path: "/r/\(folder)", mainBranch: "main", review: "github")
        }
        let ticked = [
            proposal("android", "android-app"), proposal("ios", "app"), proposal("android", "kmp"),
            proposal("web", "web-app"), proposal("go", "go"), proposal("ios", "ios"),
        ]
        #expect(RepoDetector.names(for: ticked, existing: ["web"]) == ["android", "ios", "kmp", "web-app", "go", "ios-2"])
    }

}
