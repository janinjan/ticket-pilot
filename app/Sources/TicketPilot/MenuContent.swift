import SwiftUI
import TicketPilotCore

/// The menu of the menu bar item.
struct MenuContent: View {
    let model: AppModel

    var body: some View {
        tickets("Ready to start", model.todo.ready)
        tickets("Backlog", model.todo.backlog)
        if !model.runLines.isEmpty {
            Section("In progress") {
                ForEach(model.runLines, id: \.runID, content: runItem)
            }
        }
        Divider()
        healthMenu
        Button("Check again", action: model.runDoctor)
        Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: model.setOpenAtLogin))
            .disabled(!model.hasBundle)
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder
    private func tickets(_ title: String, _ issues: [JiraIssue]) -> some View {
        if !issues.isEmpty {
            Section(title) {
                ForEach(issues) { issue in
                    Menu("\(issue.key) \(issue.summary) — \(issue.statusName)") {
                        let reason = model.startBlockReason(issue)
                        Button { model.startTicket(issue) } label: {
                            Text("Start")
                            if let reason { Text(reason) }
                        }
                        .disabled(reason != nil)
                        Button("Open in Jira") { model.openInJira(issue) }
                    }
                }
            }
        }
    }

    private func runItem(_ line: RunLine) -> some View {
        Menu {
            if let registry = model.registryLine(runID: line.runID) {
                Text(registry)
                Divider()
            }
            Button("Open session") { model.openSession(runID: line.runID) }
            Button("Resume") { model.resume(runID: line.runID) }
            if model.releasable.contains(line.runID) {
                Button("Release…") { model.release(runID: line.runID) }
            }
        } label: {
            Text(line.title)
            Text([line.detail, line.waitingFor].compactMap { $0 }.joined(separator: " · "))
        } primaryAction: {
            model.openSession(runID: line.runID)
        }
        .badge(line.isStuck ? Text("Maybe stuck") : nil)
    }

    private var healthMenu: some View {
        Menu(model.healthSummary) {
            ForEach(model.health) { check in
                Button {
                    if let fix = check.fix { model.copyToPasteboard(fix) }
                } label: {
                    Label("\(check.id.title): \(check.detail)", systemImage: check.ok ? "checkmark.circle" : "xmark.circle")
                    if let fix = check.fix { Text("Fix (click to copy): \(fix)") }
                }
            }
        }
    }
}

/// The menu bar icon: rendered to a template image, since a menu bar label shows a single image.
struct MenuBarLabel: View {
    let icon: MenuBarIcon

    var body: some View {
        Image(nsImage: render())
    }

    private func render() -> NSImage {
        let renderer = ImageRenderer(content: MenuBarGlyph(icon: icon))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }
}

private struct MenuBarGlyph: View {
    let icon: MenuBarIcon

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "ticket")
                .overlay(alignment: .topTrailing) {
                    if icon.showsAlert {
                        Circle().frame(width: 5, height: 5).offset(x: 2, y: -2)
                    }
                }
            Text(icon.countText)
            if let symbol = icon.stateSymbol {
                Image(systemName: symbol)
            }
            if let count = icon.stateCount {
                Text(String(count))
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.black)
        .padding(.vertical, 2)
    }
}
