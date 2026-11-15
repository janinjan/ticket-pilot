import AppKit
import SwiftUI
import TicketPilotCore

/// The checkouts found in a folder, to tick and add together. Each row shows what was detected; a field
/// only appears for a main branch that could not be found. Names are chosen by `RepoDetector.names`; a
/// review kind that could not be told is left out.
struct AddRepositoriesView: View {
    let folder: String
    let proposals: [RepoProposal]
    let existing: [String]
    let existingPlatforms: Set<String>
    let onAdd: ([RepoEntry]) -> Void
    let onOtherFolder: () -> Void
    let onCancel: () -> Void

    /// One value per proposal, by position: plain key-path bindings, no closure-based `Binding`.
    @State private var ticked: [Bool]
    @State private var branches: [String]

    init(
        folder: String, proposals: [RepoProposal], existing: [String], existingPlatforms: Set<String>,
        onAdd: @escaping ([RepoEntry]) -> Void, onOtherFolder: @escaping () -> Void, onCancel: @escaping () -> Void
    ) {
        self.folder = folder
        self.proposals = proposals
        self.existing = existing
        self.existingPlatforms = existingPlatforms
        self.onAdd = onAdd
        self.onOtherFolder = onOtherFolder
        self.onCancel = onCancel
        _ticked = State(initialValue: RepoDetector.defaultTicks(proposals, existingPlatforms: existingPlatforms))
        _branches = State(initialValue: proposals.map { $0.mainBranch ?? "" })
    }

    private var checked: [Int] { proposals.indices.filter { ticked[$0] } }

    /// A ticked row still missing its main branch.
    private var incomplete: Bool {
        checked.contains { branches[$0].trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(proposals.isEmpty ? "No new repository found in \(folder)." : "Repositories in \(folder)")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if !proposals.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(proposals.indices, id: \.self, content: row)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // A ScrollView has no height of its own: without one the window would shrink it to nothing.
                .frame(height: min(CGFloat(proposals.count) * 44, 400))
            }
            HStack {
                Button("Other folder…", action: onOtherFolder)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(checked.isEmpty ? "Add" : "Add \(checked.count)") {
                    let chosen = checked.map { proposals[$0] }
                    let names = RepoDetector.names(for: chosen, existing: existing)
                    onAdd(zip(checked, names).map { index, name in
                        proposals[index].entry(
                            name: name, mainBranch: branches[index].trimmingCharacters(in: .whitespaces), review: proposals[index].review
                        )
                    })
                }
                .keyboardShortcut(.defaultAction)
                .disabled(checked.isEmpty || incomplete)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func row(_ index: Int) -> some View {
        let proposal = proposals[index]
        let detected = [
            proposal.isPlatform ? RepoName.display(proposal.name) : nil,
            proposal.mainBranch,
            proposal.review.map { $0 == "gerrit" ? "Gerrit" : "GitHub" },
        ].compactMap { $0 }.joined(separator: " · ")
        return Toggle(isOn: $ticked[index]) {
            VStack(alignment: .leading, spacing: 2) {
                Text(proposal.folderName)
                HStack(spacing: 6) {
                    if !detected.isEmpty {
                        Text(detected)
                            .foregroundStyle(.secondary)
                    }
                    if proposal.mainBranch == nil {
                        TextField("Main branch", text: $branches[index])
                            .frame(width: 110)
                            .accessibilityLabel("Main branch of \(proposal.folderName)")
                    }
                }
                .font(.caption)
                .controlSize(.small)
            }
        }
        .toggleStyle(.checkbox)
        .accessibilityLabel("Add \(proposal.folderName)\(detected.isEmpty ? "" : ", \(detected)")")
    }
}

/// Shown while the folder is searched, so that the window opens at once, on the click.
private struct SearchingRepositoriesView: View {
    let folder: String
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Looking for repositories in \(folder)…")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// The window that hosts `AddRepositoriesView`, one at a time. It opens on the click, while the folder is
/// searched (`showSearching`): an app is only let to come to the front on a user action, so a window opened
/// once the search is over would stay behind the others. The list then replaces the search in place.
@MainActor
final class AddRepositoriesWindow {
    private var window: NSWindow?

    /// Still open: the user did not cancel or close it while the folder was searched.
    var isOpen: Bool { window?.isVisible == true }

    func showSearching(folder: URL) {
        present(AnyView(SearchingRepositoriesView(
            folder: (folder.path as NSString).abbreviatingWithTildeInPath,
            onCancel: { [weak self] in self?.close() }
        )))
    }

    func show(
        folder: URL, proposals: [RepoProposal], existing: [String], existingPlatforms: Set<String>,
        onAdd: @escaping ([RepoEntry]) -> Void, onOtherFolder: @escaping () -> Void
    ) {
        present(AnyView(AddRepositoriesView(
            folder: (folder.path as NSString).abbreviatingWithTildeInPath,
            proposals: proposals,
            existing: existing,
            existingPlatforms: existingPlatforms,
            onAdd: onAdd,
            onOtherFolder: onOtherFolder,
            onCancel: { [weak self] in self?.close() }
        )))
    }

    /// Replaces the content of the open window, which stays where it is; else opens one in front.
    private func present(_ view: AnyView) {
        if let window, window.isVisible {
            window.contentViewController = NSHostingController(rootView: view)
            return
        }
        close()
        let window = ClosableWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Add repositories"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
        window = nil
    }
}
