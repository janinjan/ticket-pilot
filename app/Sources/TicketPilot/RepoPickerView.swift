import SwiftUI
import TicketPilotCore

/// Choice of the repos a ticket starts on: one run per ticked repo.
struct RepoPickerView: View {
    let issue: JiraIssue
    let choices: [RepoChoice]
    let blockReason: (String) -> String?
    let onStart: ([RepoChoice]) -> Void
    let onCancel: () -> Void

    @State private var selection: Set<String>

    init(
        issue: JiraIssue,
        choices: [RepoChoice],
        initialSelection: Set<String>,
        blockReason: @escaping (String) -> String?,
        onStart: @escaping ([RepoChoice]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.issue = issue
        self.choices = choices
        self.blockReason = blockReason
        self.onStart = onStart
        self.onCancel = onCancel
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(issue.key) · \(issue.summary)")
                .font(.headline)
            ForEach(choices) { choice in
                let reason = blockReason(choice.repo.name)
                Toggle(isOn: binding(for: choice.id)) {
                    VStack(alignment: .leading) {
                        Text("\(choice.repo.name) · \(choice.existingRunID == nil ? "Start" : "Resume")")
                        if let reason {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(reason != nil)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Start") {
                    onStart(choices.filter { selection.contains($0.id) })
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selection.contains(id) },
            set: { isOn in
                if isOn { selection.insert(id) } else { selection.remove(id) }
            }
        )
    }
}
