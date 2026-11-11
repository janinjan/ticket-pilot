import SwiftUI
import TicketPilotCore

/// Choice of the repos a ticket starts on: one run per ticked repo.
struct RepoPickerView: View {
    let issue: JiraIssue
    let choices: [RepoChoice]
    let blockReason: (String) -> String?
    let onStart: ([RepoChoice]) -> Void
    let onCancel: () -> Void

    /// Whether each of `choices` is ticked, by position: plain key-path bindings, no closure-based `Binding`.
    @State private var ticked: [Bool]

    private var selection: Set<String> {
        Set(zip(choices, ticked).filter(\.1).map(\.0.id))
    }

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
        _ticked = State(initialValue: choices.map { initialSelection.contains($0.id) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(issue.key) · \(issue.summary)")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                let reason = blockReason(choice.repo.name)
                Toggle(isOn: $ticked[index]) {
                    VStack(alignment: .leading) {
                        Text("\(choice.repo.name) · \(choice.existingRunID == nil ? "Start" : "Resume")")
                            .accessibilityLabel("\(choice.repo.name), \(choice.existingRunID == nil ? "start" : "resume")")
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
                .accessibilityHint(selection.isEmpty ? "Select at least one repo" : "")
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }
}
