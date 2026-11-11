import Foundation
import Testing
@testable import TicketPilotCore

@Suite(.timeLimit(.minutes(1))) struct PluginStateTests {
    @Test func test_notInstalledIsMissing() {
        #expect(PluginState.compare(installed: nil, bundled: "0.1.3") == .missing)
        #expect(PluginState.compare(installed: nil, bundled: nil) == .missing)
    }

    @Test func test_olderInstalledIsOutdated() {
        #expect(PluginState.compare(installed: "0.1.2", bundled: "0.1.3") == .outdated(installed: "0.1.2", bundled: "0.1.3"))
        // Numeric, not textual: 0.9 is older than 0.10.
        #expect(PluginState.compare(installed: "0.9.0", bundled: "0.10.0") == .outdated(installed: "0.9.0", bundled: "0.10.0"))
        #expect(PluginState.compare(installed: "1.2", bundled: "1.2.1") == .outdated(installed: "1.2", bundled: "1.2.1"))
    }

    @Test func test_sameVersionIsCurrent() {
        #expect(PluginState.compare(installed: "0.1.3", bundled: "0.1.3") == .current)
        #expect(PluginState.compare(installed: "1.2", bundled: "1.2.0") == .current)
        #expect(PluginState.compare(installed: "v1.0.0", bundled: "1.0.0") == .current)
    }

    @Test func test_newerInstalledIsNewerThanBundled() {
        #expect(PluginState.compare(installed: "0.10.0", bundled: "0.9.9") == .newerThanBundled)
        #expect(PluginState.compare(installed: "2.0.0", bundled: "1.99.99") == .newerThanBundled)
    }

    @Test func test_unreadableVersionIsUnknown() {
        #expect(PluginState.compare(installed: "0.1.3", bundled: nil) == .unknown)
        #expect(PluginState.compare(installed: "unknown", bundled: "0.1.3") == .unknown)
        #expect(PluginState.compare(installed: "0.1.3", bundled: "abc") == .unknown)
        #expect(PluginState.compare(installed: "", bundled: "0.1.3") == .unknown)
    }

    @Test func test_preReleaseAndBuildSuffixesAreIgnored() {
        #expect(PluginState.compare(installed: "0.1.3-beta", bundled: "0.1.3") == .current)
        #expect(PluginState.compare(installed: "0.1.2+abc", bundled: "0.1.3") == .outdated(installed: "0.1.2+abc", bundled: "0.1.3"))
    }

    @Test func test_onlyMissingAndOutdatedNeedTheInstaller() {
        #expect(PluginState.missing.needsInstall)
        #expect(PluginState.outdated(installed: "1", bundled: "2").needsInstall)
        #expect(!PluginState.current.needsInstall)
        #expect(!PluginState.newerThanBundled.needsInstall)
        #expect(!PluginState.unknown.needsInstall)
    }
}
