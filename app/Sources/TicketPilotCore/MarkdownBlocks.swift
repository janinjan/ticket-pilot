import Foundation

/// A block of a run report, as the report window draws it. The text inside a block keeps its inline
/// Markdown (bold, code, links), rendered by the view.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// `marker` is "•" for a bullet, else the item's number ("1.").
    case listItem(marker: String, text: String)
    case quote(String)
    case code(String)
    case table(header: [String], rows: [[String]])
    case rule
}

/// The few block kinds a report uses (CommonMark subset): headings, paragraphs, lists, quotes, fenced
/// code, pipe tables and rules.
public enum MarkdownBlocks {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushParagraph()
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(code.joined(separator: "\n")))
                index += 1
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
            } else if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
            } else if trimmed == "---" || trimmed == "***" {
                flushParagraph()
                blocks.append(.rule)
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    quoted.append(String(current.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: " ")))
                continue
            } else if trimmed.hasPrefix("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                flushParagraph()
                let header = cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix("|") else { break }
                    rows.append(cells(current))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            } else if let item = listItem(line) {
                flushParagraph()
                blocks.append(item)
            } else if case let .listItem(marker, text)? = blocks.last, paragraph.isEmpty,
                      line.hasPrefix("  ") {
                // An indented line continues the item above it.
                blocks[blocks.count - 1] = .listItem(marker: marker, text: text + " " + trimmed)
            } else {
                paragraph.append(trimmed)
            }
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> MarkdownBlock? {
        let indent = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(indent)
        let nested = indent >= 2 ? "◦" : "•"
        for bullet in ["- ", "* ", "+ "] where rest.hasPrefix(bullet) {
            return .listItem(marker: nested, text: String(rest.dropFirst(2)))
        }
        let digits = rest.prefix(while: \.isNumber)
        if !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix(". ") {
            return .listItem(marker: "\(digits).", text: String(rest.dropFirst(digits.count + 2)))
        }
        return nil
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") && trimmed.contains("-")
            && trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var inner = Substring(line)
        if inner.hasPrefix("|") { inner = inner.dropFirst() }
        if inner.hasSuffix("|") { inner = inner.dropLast() }
        return inner.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
