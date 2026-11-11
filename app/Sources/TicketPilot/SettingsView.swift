import SwiftUI
import TicketPilotCore

/// The Settings window: Open at login, the terminal, and every setup check.
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: model.setOpenAtLogin))
                    .disabled(!model.hasBundle)
                    .accessibilityHint(model.hasBundle ? "" : "Only available when TicketPilot runs from its app")
                Picker("Terminal", selection: Binding(get: { model.selectedTerminal }, set: model.setTerminalApp)) {
                    Text("Automatic (\(model.automaticTerminal?.appName ?? "…"))")
                        .tag(String?.none)
                    ForEach(model.terminalOptions, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                .disabled(model.configError != nil)
                .accessibilityHint(model.configError == nil ? "" : "Fix the config first, see Diagnostics")
            } footer: {
                Text("Sessions open in this terminal. The choice is saved as terminal_app in your config.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Diagnostics") {
                if let configError = model.configError {
                    CheckRow(ok: false, title: "Config", detail: configError)
                } else if model.health.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking…")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(model.health) { check in
                    CheckRow(ok: check.ok, title: check.id.title, detail: check.detail, fix: check.fix) {
                        if check.id == .jiraToken, !check.ok, check.needsToken {
                            Button("Set Jira token…", action: model.setJiraToken)
                        } else if check.fix != nil {
                            Button(model.copiedFix == check.id ? "Copied ✓" : "Copy fix command") {
                                model.copyFix(of: check)
                            }
                            .accessibilityLabel(
                                model.copiedFix == check.id ? "Copied" : "Copy fix command for \(check.id.title)"
                            )
                        }
                    }
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Check again", action: model.runDoctor)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 420, idealHeight: 640)
    }
}

private struct CheckRow<Actions: View>: View {
    let ok: Bool
    let title: String
    let detail: String
    var fix: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // A failed check is something to set up, not an alarm: orange, never red.
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Color(nsColor: .systemGreen) : Brand.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let fix {
                    Text(fix)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(ok ? "Passed" : "To fix")
            Spacer(minLength: 8)
            actions
                .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
    }
}

extension CheckRow where Actions == EmptyView {
    init(ok: Bool, title: String, detail: String) {
        self.init(ok: ok, title: title, detail: detail, fix: nil) { EmptyView() }
    }
}
