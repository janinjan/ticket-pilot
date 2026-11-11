import AppKit
import SwiftUI
import TicketPilotCore

/// The panel under the menu bar item: the state at a glance, the runs, the tickets to do, and the setup fix.
struct PanelView: View {
    let model: AppModel

    /// Beyond this, the runs and tickets scroll.
    private static let maxListHeight: CGFloat = 400

    @Environment(\.dismiss) private var dismiss
    @State private var listHeight: CGFloat = 0
    @State private var host = HostWindow()

    var body: some View {
        VStack(spacing: 0) {
            header
            top
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 10)
            if hasList {
                Divider()
                ScrollView {
                    list
                        .padding(12)
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { listHeight = $0 }
                }
                .frame(height: min(max(listHeight, 1), Self.maxListHeight))
            }
            Divider()
            footer
        }
        .frame(width: 300)
        .background(HostWindowReader(host: host))
    }

    private var hasList: Bool {
        !model.runGroups.isEmpty || !model.todo.sections.isEmpty
    }

    /// Closes the panel, then acts: an alert, a window or another app comes next. Should `dismiss` leave
    /// the panel on screen, its window is closed directly.
    private func closing(_ action: @escaping @MainActor () -> Void) -> () -> Void {
        {
            dismiss()
            let host = host
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                if let window = host.window, window.isVisible { window.close() }
                action()
            }
        }
    }

    // MARK: - Header and status

    private var header: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            Text("TicketPilot")
                .font(.headline)
            Spacer()
            Menu {
                Button("About TicketPilot", action: closing(model.showAbout))
                Button("Settings…", action: closing(model.showSettings))
                    .keyboardShortcut(",")
                Button("Send feedback", action: closing(model.sendFeedback))
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(minWidth: 28, minHeight: 28)
            .contentShape(Rectangle())
            .accessibilityLabel("Settings and more")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.top, 6)
    }

    /// Quit, always in sight, as in the other menu bar apps.
    private var footer: some View {
        HStack {
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.callout)
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// The status line; with a setup problem, a banner that holds its fix button.
    @ViewBuilder
    private var top: some View {
        let status = model.status
        let text = VStack(alignment: .leading, spacing: 2) {
            Text(status.headline)
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if let subtitle = status.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        if status.needsSetup, model.signingIn || model.setupProblemTitle != nil {
            VStack(alignment: .leading, spacing: 8) {
                text
                if model.signingIn {
                    // Stays open: the sign-in goes on in the browser.
                    Button("Cancel", action: model.cancelSignIn)
                        .accessibilityLabel("Cancel the Atlassian sign-in")
                } else if let title = model.setupProblemTitle {
                    setupButton(title)
                }
            }
            .padding(10)
            .background(Brand.orange.opacity(0.12), in: Card.shape)
            .overlay(Card.shape.strokeBorder(Brand.orange.opacity(0.3), lineWidth: 1))
            .accessibilityElement(children: .contain)
        } else {
            text
        }
    }

    // MARK: - Runs and tickets

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.runGroups, id: \.section) { group in
                VStack(alignment: .leading, spacing: 6) {
                    SectionTitle(group.section.title)
                    ForEach(group.lines, id: \.runID, content: runCard)
                }
            }
            ForEach(model.todo.sections, id: \.title) { section in
                VStack(alignment: .leading, spacing: 6) {
                    SectionTitle(section.title)
                    VStack(spacing: 0) {
                        ForEach(Array(section.issues.enumerated()), id: \.element.id) { index, issue in
                            if index > 0 { Divider().padding(.leading, 10) }
                            ticketRow(issue)
                        }
                    }
                    .background(Card.background, in: Card.shape)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func runCard(_ line: RunLine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(line.title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if line.isStuck {
                            StuckTag()
                        }
                    }
                    .accessibilityElement(children: .combine)
                    sessionButton(line)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.context)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(line.detail)
                        .font(.callout)
                        .foregroundStyle(line.section == .needsYou ? .primary : .secondary)
                        .lineLimit(line.section == .needsYou ? nil : 3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                .accessibilityElement(children: .combine)
            }
            if let filled = line.filledSteps {
                StepDots(filled: filled, total: RunLine.stepCount, description: line.progressDescription ?? "")
            }
            secondaryRunButtons(line)
        }
        .padding(10)
        .background(Card.background, in: Card.shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(line.isStuck ? "\(line.name), maybe stuck" : line.name)
    }

    /// "Show in Finder" and "Release…", under the card's text; nothing when neither applies.
    @ViewBuilder
    private func secondaryRunButtons(_ line: RunLine) -> some View {
        let finderTitle = line.section == .reportReady ? model.showInFinderTitle(runID: line.runID) : nil
        let releasable = model.releasable.contains(line.runID)
        if finderTitle != nil || releasable {
            HStack(spacing: 6) {
                if let finderTitle {
                    finderButton(line, title: finderTitle)
                }
                if releasable {
                    Button(action: closing { model.release(runID: line.runID) }) {
                        Text("Release…")
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .buttonStyle(.brandSecondary)
                    .accessibilityLabel("Release \(line.name)")
                }
            }
            .padding(.top, 2)
        }
    }

    private func finderButton(_ line: RunLine, title finderTitle: String) -> some View {
        Button(action: closing { model.revealWorktree(runID: line.runID) }) {
            HStack(spacing: 4) {
                Text("Show in Finder")
                if let size = model.worktreeSize(runID: line.runID) {
                    Text(size)
                        .foregroundStyle(.tertiary)
                }
            }
            .lineLimit(1)
            .fixedSize()
        }
        .buttonStyle(.brandSecondary)
        .help("Reveal the worktree in the Finder")
        .accessibilityLabel("\(finderTitle), \(line.name)")
    }

    private func sessionButton(_ line: RunLine) -> some View {
        Button(action: closing { model.openSession(runID: line.runID) }) {
            Text(line.sessionButton)
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(.brand)
        .help("Opens the session in your terminal")
        .accessibilityLabel("\(line.sessionButton), \(line.name)")
    }

    private func ticketRow(_ issue: JiraIssue) -> some View {
        let reason = model.startBlockReason(issue)
        return HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.summary)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(issue.summary)
                Text("\(issue.key) · \(issue.statusName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            Menu {
                Button("Open in Jira", action: closing { model.openInJira(issue) })
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(minWidth: 28, minHeight: 28)
            .contentShape(Rectangle())
            .accessibilityLabel("More for \(issue.key)")
            Button("Start", action: closing { model.startTicket(issue) })
                .buttonStyle(.brand)
                .disabled(reason != nil)
                .help(reason ?? "Start \(issue.key)")
                .accessibilityLabel("Start \(issue.key)")
                .accessibilityHint(reason.map { "Unavailable: \($0)" } ?? "")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Start", action: closing { model.startTicket(issue) })
                .disabled(reason != nil)
            Button("Open in Jira", action: closing { model.openInJira(issue) })
        }
    }

    // MARK: - Setup

    private func setupButton(_ title: String) -> some View {
        // Copying a fix or checking again keeps the panel open, to show "Copied ✓" or the new state.
        let staysOpen = switch model.setupProblem?.action {
        case .copyFix, .checkAgain: true
        default: false
        }
        return Button(title, action: staysOpen ? model.fixSetupProblem : closing(model.fixSetupProblem))
            .buttonStyle(.brand)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(title == "Copied ✓" ? "Copied" : title.replacingOccurrences(of: " →", with: ""))
    }
}

/// The panel's own window, to close it should `dismiss` not.
@MainActor
private final class HostWindow {
    weak var window: NSWindow?
}

private struct HostWindowReader: NSViewRepresentable {
    let host: HostWindow

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.host = host
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var host: HostWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            host?.window = window
        }
    }
}

private struct SectionTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// "Maybe stuck": the text in the primary colour for contrast, the orange only on the symbol.
private struct StuckTag: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Brand.orange)
                .accessibilityHidden(true)
            Text("Maybe stuck")
                .foregroundStyle(.primary)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Brand.orange.opacity(0.18), in: Capsule())
    }
}

private enum Card {
    static let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    static let background = Color.primary.opacity(0.06)
}

/// One dot per step of the plugin, filled up to the current one; one VoiceOver element.
private struct StepDots: View {
    let filled: Int
    let total: Int
    let description: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<total, id: \.self) { index in
                if index < filled {
                    Circle().fill(Brand.orange)
                        .frame(width: 6, height: 6)
                } else {
                    Circle().strokeBorder(.secondary, lineWidth: 1)
                        .frame(width: 6, height: 6)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(description)
    }
}
