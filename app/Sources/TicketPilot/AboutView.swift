import AppKit
import SwiftUI

/// The About window: the app icon, the name, the version, the copyright and the license. No links.
struct AboutView: View {
    private var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version.map { "Version \($0)" } ?? "Development build"
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("TicketPilot")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(version)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            VStack(spacing: 2) {
                Text("Copyright © 2026 Janin Culhaoglu")
                Text("MIT License")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .frame(width: 320)
    }
}
