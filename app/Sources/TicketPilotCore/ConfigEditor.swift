import Foundation

public enum ConfigEditError: Error, Equatable {
    case invalidJSON
    case notAnObject
    /// The terminal name could not be written as a JSON string.
    case invalidName
}

/// Edits the user's config file without losing anything else in it: every other key keeps its place and
/// every value its spelling (numbers and strings are copied as written). The output is pretty-printed with
/// two spaces; an array of plain values stays on one line.
public enum ConfigEditor {
    /// Writes `/` as is, so that a path or a URL stays readable in the file.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return encoder
    }

    /// Sets `terminal_app` to `name`, or removes it when `name` is nil ("Automatic"). A new key goes at
    /// the end of the top-level object; with duplicate keys, the last one (the one readers use) is set and
    /// the others are removed. A byte order mark is dropped.
    public static func setTerminalApp(_ name: String?, in data: Data) throws(ConfigEditError) -> Data {
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else { throw .invalidJSON }
        var parser = Parser(bytes: Array(data))
        let root: Value
        do {
            root = try parser.document()
        } catch {
            throw .invalidJSON
        }
        guard case var .object(members) = root else { throw .notAnObject }
        let key = "\"terminal_app\""
        if let name {
            guard let encoded = try? encoder.encode(name) else { throw .invalidName }
            set(key, to: .scalar(String(decoding: encoded, as: UTF8.self)), in: &members)
        } else {
            members.removeAll { $0.key == key }
        }
        return Data((render(.object(members), indent: "") + "\n").utf8)
    }

    /// nil `data`: a new config, `{"jira": {"site"}, "repos": []}`. Else sets only what is missing: `jira.site`
    /// (never a value already written), the `jira` object and the `repos` list.
    public static func fillJira(site: URL, in data: Data?) throws(ConfigEditError) -> Data {
        var members = try data.map { data throws(ConfigEditError) in try topLevel(of: data) } ?? []
        var jira: [(key: String, value: Value)] = []
        if let index = members.lastIndex(where: { $0.key == "\"jira\"" }) {
            guard case let .object(existing) = members[index].value else { throw .notAnObject }
            jira = existing
        }
        if !jira.contains(where: { $0.key == "\"site\"" }) {
            jira.append(("\"site\"", try string(site.absoluteString)))
        }
        set("\"jira\"", to: .object(jira), in: &members)
        if !members.contains(where: { $0.key == "\"repos\"" }) {
            members.append(("\"repos\"", .array([])))
        }
        return Data((render(.object(members), indent: "") + "\n").utf8)
    }

    /// Appends `repo` to `repos` (created when absent), with its `match` rules.
    public static func addRepo(_ repo: RepoEntry, in data: Data) throws(ConfigEditError) -> Data {
        var members = try topLevel(of: data)
        var repos: [Value] = []
        if let index = members.lastIndex(where: { $0.key == "\"repos\"" }) {
            guard case let .array(existing) = members[index].value else { throw .notAnObject }
            repos = existing
        }
        func strings(_ values: [String]) throws(ConfigEditError) -> Value {
            var items: [Value] = []
            for value in values { items.append(try string(value)) }
            return .array(items)
        }
        var fields: [(key: String, value: Value)] = [
            ("\"name\"", try string(repo.name)),
            ("\"path\"", try string(repo.path)),
            ("\"main_branch\"", try string(repo.mainBranch)),
        ]
        if let review = repo.review { fields.append(("\"review\"", try string(review))) }
        fields.append(("\"match\"", .object([
            ("\"title_prefixes\"", try strings(repo.titlePrefixes)),
            ("\"labels\"", try strings(repo.labels)),
            ("\"components\"", try strings(repo.components)),
        ])))
        repos.append(.object(fields))
        set("\"repos\"", to: .array(repos), in: &members)
        return Data((render(.object(members), indent: "") + "\n").utf8)
    }

    /// Removes the entries of `repos` named `name`, every other key kept.
    public static func removeRepo(named name: String, in data: Data) throws(ConfigEditError) -> Data {
        var members = try topLevel(of: data)
        guard let index = members.lastIndex(where: { $0.key == "\"repos\"" }),
              case let .array(repos) = members[index].value
        else { throw .notAnObject }
        let key = try string(name)
        members[index].value = .array(repos.filter { repo in
            guard case let .object(fields) = repo else { return true }
            return !fields.contains { field in
                guard field.key == "\"name\"", case let .scalar(text) = field.value else { return false }
                // Compared decoded, so that an escaped spelling in the file still matches.
                return decoded(text) == decoded(scalarText(key))
            }
        })
        return Data((render(.object(members), indent: "") + "\n").utf8)
    }

    private static func topLevel(of data: Data) throws(ConfigEditError) -> [(key: String, value: Value)] {
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else { throw .invalidJSON }
        var parser = Parser(bytes: Array(data))
        let root: Value
        do {
            root = try parser.document()
        } catch {
            throw .invalidJSON
        }
        guard case let .object(members) = root else { throw .notAnObject }
        return members
    }

    private static func string(_ value: String) throws(ConfigEditError) -> Value {
        guard let encoded = try? encoder.encode(value) else { throw .invalidName }
        return .scalar(String(decoding: encoded, as: UTF8.self))
    }

    private static func scalarText(_ value: Value) -> String {
        if case let .scalar(text) = value { text } else { "" }
    }

    private static func decoded(_ text: String) -> String? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) as? String
    }

    /// Replaces the last `key` (dropping its duplicates), else appends it.
    private static func set(_ key: String, to value: Value, in members: inout [(key: String, value: Value)]) {
        if let last = members.lastIndex(where: { $0.key == key }) {
            members[last].value = value
            members = members.enumerated().filter { $0.offset == last || $0.element.key != key }.map(\.element)
        } else {
            members.append((key, value))
        }
    }

    /// A JSON value; keys and scalars are kept as their source text.
    fileprivate indirect enum Value {
        case scalar(String)
        case array([Value])
        case object([(key: String, value: Value)])

        var isScalar: Bool {
            if case .scalar = self { true } else { false }
        }
    }

    private static func render(_ value: Value, indent: String) -> String {
        let inner = indent + "  "
        switch value {
        case let .scalar(text):
            return text
        case let .array(items):
            if items.isEmpty { return "[]" }
            if items.allSatisfy(\.isScalar) {
                return "[" + items.map { render($0, indent: inner) }.joined(separator: ", ") + "]"
            }
            return "[\n" + items.map { inner + render($0, indent: inner) }.joined(separator: ",\n") + "\n\(indent)]"
        case let .object(members):
            if members.isEmpty { return "{}" }
            return "{\n" + members.map { inner + $0.key + ": " + render($0.value, indent: inner) }
                .joined(separator: ",\n") + "\n\(indent)}"
        }
    }

    private struct ParseError: Error {}

    /// A strict enough JSON reader: the document was already validated by `JSONSerialization`.
    private struct Parser {
        let bytes: [UInt8]
        var position = 0

        mutating func document() throws -> Value {
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { position = 3 }
            let value = try self.value()
            skipWhitespace()
            guard position == bytes.count else { throw ParseError() }
            return value
        }

        private mutating func value() throws -> Value {
            skipWhitespace()
            guard position < bytes.count else { throw ParseError() }
            switch bytes[position] {
            case UInt8(ascii: "{"):
                position += 1
                var members: [(key: String, value: Value)] = []
                skipWhitespace()
                if consume(UInt8(ascii: "}")) { return .object(members) }
                repeat {
                    skipWhitespace()
                    let key = try string()
                    skipWhitespace()
                    try expect(UInt8(ascii: ":"))
                    members.append((key, try value()))
                    skipWhitespace()
                } while consume(UInt8(ascii: ","))
                try expect(UInt8(ascii: "}"))
                return .object(members)
            case UInt8(ascii: "["):
                position += 1
                var items: [Value] = []
                skipWhitespace()
                if consume(UInt8(ascii: "]")) { return .array(items) }
                repeat {
                    items.append(try value())
                    skipWhitespace()
                } while consume(UInt8(ascii: ","))
                try expect(UInt8(ascii: "]"))
                return .array(items)
            case UInt8(ascii: "\""):
                return .scalar(try string())
            default:
                let start = position
                while position < bytes.count, !Self.delimiters.contains(bytes[position]) { position += 1 }
                guard position > start else { throw ParseError() }
                return .scalar(String(decoding: bytes[start..<position], as: UTF8.self))
            }
        }

        /// A string literal, quotes and escapes included, as written.
        private mutating func string() throws -> String {
            let start = position
            try expect(UInt8(ascii: "\""))
            while position < bytes.count, bytes[position] != UInt8(ascii: "\"") {
                position += bytes[position] == UInt8(ascii: "\\") ? 2 : 1
            }
            try expect(UInt8(ascii: "\""))
            return String(decoding: bytes[start..<position], as: UTF8.self)
        }

        private static let delimiters: Set<UInt8> = Set(" \t\r\n,]}:".utf8)

        private mutating func skipWhitespace() {
            while position < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[position]) { position += 1 }
        }

        private mutating func consume(_ byte: UInt8) -> Bool {
            guard position < bytes.count, bytes[position] == byte else { return false }
            position += 1
            return true
        }

        private mutating func expect(_ byte: UInt8) throws {
            guard consume(byte) else { throw ParseError() }
        }
    }
}

/// A repository entry the app writes into `repos`.
public struct RepoEntry: Equatable, Sendable {
    public var name: String
    public var path: String
    public var mainBranch: String
    public var review: String?
    public var titlePrefixes: [String]
    public var labels: [String]
    public var components: [String]

    public init(
        name: String, path: String, mainBranch: String, review: String?,
        titlePrefixes: [String], labels: [String], components: [String]
    ) {
        self.name = name
        self.path = path
        self.mainBranch = mainBranch
        self.review = review
        self.titlePrefixes = titlePrefixes
        self.labels = labels
        self.components = components
    }
}
