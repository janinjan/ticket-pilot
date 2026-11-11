import Foundation
import Testing
@testable import TicketPilotCore

@Suite(.timeLimit(.minutes(1))) struct ToolChoiceTests {
    @Test func test_theGitClientIsTheConfiguredOneElseTheFirstInstalled() {
        #expect(ToolChoice.gitClient(configured: "Fork", installed: ["GitHub Desktop"]) == "Fork")
        #expect(ToolChoice.gitClient(configured: nil, installed: ["Tower", "Fork"]) == "Fork")
        #expect(ToolChoice.gitClient(configured: "  ", installed: ["GitKraken"]) == "GitKraken")
        #expect(ToolChoice.gitClient(configured: nil, installed: ["Xcode"]) == nil)
        #expect(ToolChoice.gitClients == ["GitHub Desktop", "Fork", "Tower", "Sourcetree", "GitKraken"])
    }

    @Test func test_theEditorFollowsTheProjectType() {
        let all = ["Xcode", "Android Studio", "Visual Studio Code", "Cursor", "WebStorm"]
        func editor(_ entries: [String], installed: [String] = all) -> EditorTarget? {
            ToolChoice.editor(configured: nil, worktree: "/wt", entries: entries, installed: installed)
        }
        #expect(editor(["App.xcodeproj", "App.xcworkspace"]) == EditorTarget(app: "Xcode", path: "/wt/App.xcworkspace"))
        #expect(editor(["App.xcodeproj", "README.md"]) == EditorTarget(app: "Xcode", path: "/wt/App.xcodeproj"))
        #expect(editor(["Package.swift"]) == EditorTarget(app: "Xcode", path: "/wt"))
        #expect(editor(["settings.gradle.kts"]) == EditorTarget(app: "Android Studio", path: "/wt"))
        #expect(editor(["build.gradle"])?.app == "Android Studio")
        #expect(editor(["package.json"]) == EditorTarget(app: "Visual Studio Code", path: "/wt"))
        #expect(editor(["package.json"], installed: ["WebStorm", "Cursor"])?.app == "Cursor")
        // Only installed apps are offered.
        #expect(editor(["App.xcodeproj"], installed: ["Visual Studio Code"]) == nil)
        #expect(editor(["Makefile"]) == nil)
    }

    @Test func test_aConfiguredEditorWinsAndXcodeStillOpensTheProject() {
        #expect(ToolChoice.editor(configured: "Cursor", worktree: "/wt", entries: ["App.xcodeproj"], installed: [])
            == EditorTarget(app: "Cursor", path: "/wt"))
        #expect(ToolChoice.editor(configured: "Xcode", worktree: "/wt", entries: ["App.xcodeproj"], installed: [])
            == EditorTarget(app: "Xcode", path: "/wt/App.xcodeproj"))
    }

    @Test func test_installedAppsComeFromTheApplicationFolders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-apps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Fork.app"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let finder = ApplicationFinder(directories: [dir])
        #expect(finder.installed(among: ["GitHub Desktop", "Fork"]) == ["Fork"])
    }

    @Test func test_aVersionedXcodeCountsAsXcode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-apps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Xcode_27.1.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Forked.app"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ApplicationFinder(directories: [dir]).installed(among: ["Xcode", "Fork"]) == ["Xcode"])
    }

    @Test func test_xcodeOpensByItsBundleIDWhateverItsFileName() throws {
        let runner = FakeRunner()
        try ToolLauncher(runner: runner).open(EditorTarget(app: "Xcode", path: "/wt/App.xcodeproj"))
        #expect(runner.calls == [FakeRunner.Call(
            executable: "/usr/bin/open", arguments: ["-b", "com.apple.dt.Xcode", "/wt/App.xcodeproj"]
        )])
    }

    @Test func test_opensWithTheChosenApp() throws {
        let runner = FakeRunner()
        try ToolLauncher(runner: runner).open(EditorTarget(app: "GitHub Desktop", path: "/w t"))
        #expect(runner.calls == [FakeRunner.Call(executable: "/usr/bin/open", arguments: ["-a", "GitHub Desktop", "/w t"])])
    }
}

@Suite(.timeLimit(.minutes(1))) struct NewestAppTests {
    static func app(_ path: String, _ version: String?, plain: Bool = false) -> AppCandidate {
        AppCandidate(path: path, version: version, isPlainName: plain)
    }

    @Test func test_theHighestVersionWinsComparedAsNumbers() {
        #expect(AppCandidate.newest([Self.app("/A/Xcode_27.app", "27.0"), Self.app("/A/Xcode_27.1.app", "27.1")])?.path
            == "/A/Xcode_27.1.app")
        #expect(AppCandidate.newest([Self.app("/A/S10.app", "10.0"), Self.app("/A/S9.app", "9.4.1")])?.path == "/A/S10.app")
        #expect(AppCandidate.newest([Self.app("/A/a.app", "27"), Self.app("/A/b.app", "27.0.1")])?.path == "/A/b.app")
    }

    @Test func test_aMissingVersionLosesAndATieGoesToThePlainName() {
        #expect(AppCandidate.newest([Self.app("/A/X-beta.app", nil), Self.app("/A/X_1.app", "1.0")])?.path == "/A/X_1.app")
        #expect(AppCandidate.newest([Self.app("/A/X_2.app", "2.0"), Self.app("/A/X.app", "2.0", plain: true)])?.path
            == "/A/X.app")
        #expect(AppCandidate.newest([Self.app("/A/X.app", nil, plain: true)])?.path == "/A/X.app")
        #expect(AppCandidate.newest([]) == nil)
    }

    @Test func test_theFinderPicksTheNewestCopyAmongItsVariants() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-apps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        func make(_ name: String, version: String?) throws {
            let contents = dir.appendingPathComponent("\(name).app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: [String: String] = version.map { ["CFBundleShortVersionString": $0] } ?? [:]
            try (info as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
        }
        try make("Xcode_27", version: "27.0")
        try make("Xcode_27.1", version: "27.1")
        try make("Android Studio", version: "2026.2")
        try make("Android Studio Preview", version: "2026.3")
        try make("Forked", version: "9.0")
        let finder = ApplicationFinder(directories: [dir])
        #expect(finder.locate("Xcode") == dir.appendingPathComponent("Xcode_27.1.app").path)
        #expect(finder.locate("Android Studio") == dir.appendingPathComponent("Android Studio Preview.app").path)
        #expect(finder.locate("Fork") == nil)
        #expect(finder.installed(among: ["Xcode", "Fork", "Android Studio"]) == ["Xcode", "Android Studio"])
    }

    @Test func test_theExactAppIsOpenedAndAConfiguredPathIsKept() throws {
        let runner = FakeRunner()
        try ToolLauncher(runner: runner).open(EditorTarget(app: "Xcode", path: "/wt/A.xcodeproj", appPath: "/A/Xcode_27.1.app"))
        #expect(runner.calls.last?.arguments == ["-a", "/A/Xcode_27.1.app", "/wt/A.xcodeproj"])
        let chosen = ToolChoice.editor(
            configured: "/A/Xcode_27.app", worktree: "/wt", entries: ["A.xcodeproj"], installed: []
        )
        #expect(chosen == EditorTarget(app: "Xcode_27", path: "/wt/A.xcodeproj", appPath: "/A/Xcode_27.app"))
        let found = ToolChoice.editor(
            configured: nil, worktree: "/wt", entries: ["A.xcodeproj"], installed: ["Xcode"],
            appPaths: ["Xcode": "/A/Xcode_27.1.app"]
        )
        #expect(found?.appPath == "/A/Xcode_27.1.app")
    }
}
