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
            guard let encoded = try? JSONEncoder().encode(name) else { throw .invalidName }
            set(key, to: .scalar(String(decoding: encoded, as: UTF8.self)), in: &members)
        } else {
            members.removeAll { $0.key == key }
        }
        return Data((render(.object(members), indent: "") + "\n").utf8)
    }

    /// Sets `jira.auth` to `value` (`mcp` or `api_token`), every other key kept; a new key goes at the end
    /// of the `jira` object.
    public static func setJiraAuth(_ value: String, in data: Data) throws(ConfigEditError) -> Data {
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else { throw .invalidJSON }
        var parser = Parser(bytes: Array(data))
        let root: Value
        do {
            root = try parser.document()
        } catch {
            throw .invalidJSON
        }
        guard case var .object(members) = root,
              let jiraIndex = members.lastIndex(where: { $0.key == "\"jira\"" }),
              case var .object(jira) = members[jiraIndex].value
        else { throw .notAnObject }
        guard let encoded = try? JSONEncoder().encode(value) else { throw .invalidName }
        set("\"auth\"", to: .scalar(String(decoding: encoded, as: UTF8.self)), in: &jira)
        members[jiraIndex].value = .object(jira)
        return Data((render(.object(members), indent: "") + "\n").utf8)
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
