import AppKit
import SwiftUI
import TicketPilotCore

/// The windows that show a run's saved report, one per run, brought to the front when asked again.
@MainActor
final class ReportWindows {
    private var windows: [String: NSWindow] = [:]

    func show(runID: String, key: String, report: String) {
        let view = ReportView(blocks: MarkdownBlocks.parse(report))
        if let window = windows[runID] {
            (window.contentViewController as? NSHostingController<ReportView>)?.rootView = view
        } else {
            let window = ClosableWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Report · \(key)"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 720, height: 760))
            window.center()
            windows[runID] = window
        }
        NSApp.activate()
        windows[runID]?.makeKeyAndOrderFront(nil)
    }

    func close(runID: String) {
        windows.removeValue(forKey: runID)?.close()
    }
}

struct ReportView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    BlockView(block: block)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(minWidth: 480, minHeight: 360)
    }
}

private struct BlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case let .heading(level, text):
            Inline(text)
                .font(level == 1 ? .title : level == 2 ? .title2 : .title3)
                .fontWeight(.semibold)
                .padding(.top, level == 1 ? 0 : 8)
                .accessibilityAddTraits(.isHeader)
        case let .paragraph(text):
            Inline(text)
        case let .listItem(marker, text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .foregroundStyle(.secondary)
                    .padding(.leading, marker == "◦" ? 16 : 0)
                    .accessibilityHidden(true)
                Inline(text)
            }
        case let .quote(text):
            Inline(text)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: 3)
                }
        case let .code(text):
            Text(text)
                .font(.body.monospaced())
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        case let .table(header, rows):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Inline(cell).fontWeight(.semibold)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Inline(cell)
                        }
                    }
                }
            }
        case .rule:
            Divider()
        }
    }
}

/// One block's text with its inline Markdown (bold, italics, code, links); as typed when it does not parse.
private struct Inline: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(rendered)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var rendered: AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
