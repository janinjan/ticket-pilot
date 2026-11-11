import SwiftUI
import TicketPilotCore

/// The Settings window: Open at login, the terminal, the Jira connection, and every setup check.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $model.openAtLogin)
                    .disabled(!model.hasBundle)
                    .accessibilityHint(model.hasBundle ? "" : "Only available when TicketPilot runs from its app")
                Toggle("Play a sound when TicketPilot needs you", isOn: $model.playsSound)
                    .disabled(!model.hasBundle)
                    .accessibilityHint(model.hasBundle ? "" : "Only available when TicketPilot runs from its app")
                VStack(alignment: .leading, spacing: 2) {
                    Button("Send a test notification", action: model.sendTestNotification)
                        .disabled(!model.hasBundle)
                    if let status = model.notificationStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onAppear(perform: model.refreshNotificationStatus)
                Picker("Terminal", selection: $model.terminalChoiceName) {
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
            JiraSection(model: model)
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
                        } else if check.id == .jiraSignIn, !check.ok, check.needsToken {
                            Button("Connect…", action: model.connectAtlassian)
                                .disabled(model.signingIn)
                                .accessibilityLabel("Connect Jira")
                        } else if let state = check.pluginState, state.needsInstall, model.health.claudePath != nil {
                            Button(state == .missing ? "Install…" : "Update…") { model.installPlugin(state) }
                                .disabled(model.installingPlugin)
                                .accessibilityLabel(state == .missing ? "Install the plugin" : "Update the plugin")
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

/// How Jira is read: the Atlassian sign-in (connected or not), or an API token; and the switch between them.
private struct JiraSection: View {
    let model: AppModel

    var body: some View {
        Section {
            switch model.jiraAuth {
            case .mcp:
                HStack(spacing: 8) {
                    if model.signingIn {
                        ProgressView()
                            .controlSize(.small)
                        Text("Waiting for Atlassian sign-in…")
                        Spacer(minLength: 8)
                        Button("Cancel", action: model.cancelSignIn)
                            .accessibilityLabel("Cancel the Atlassian sign-in")
                    } else if model.hasAtlassianSignIn {
                        Text(model.jiraAccount.map { "Connected as \($0)" } ?? "Connected via Atlassian MCP")
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        Button("Disconnect", action: model.disconnectJira)
                            .accessibilityLabel("Disconnect Jira")
                    } else {
                        Text("Not connected")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Connect Jira…", action: model.connectAtlassian)
                    }
                }
                .controlSize(.small)
                Button("Use an API token instead…", action: model.useAPIToken)
                    .buttonStyle(.link)
                    .accessibilityHint("Saves jira.auth as api_token in your config, then asks for the token")
            case .apiToken:
                HStack(spacing: 8) {
                    Text("API token")
                    Spacer(minLength: 8)
                    Button("Set Jira token…", action: model.setJiraToken)
                        .controlSize(.small)
                }
                Button("Use the Atlassian sign-in instead…", action: model.useAtlassianSignIn)
                    .buttonStyle(.link)
                    .accessibilityHint("Saves jira.auth as mcp in your config, then opens the Atlassian sign-in")
            }
        } header: {
            Text("Jira")
        } footer: {
            Text(model.jiraAuth == .mcp
                ? "Signed in through the Atlassian MCP server. The sign-in stays in your Mac's Keychain."
                : "Reads Jira with your API token, kept in your Mac's Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(model.configError != nil)
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
