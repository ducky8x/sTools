import Foundation

/// A syntax error with a 1-based position.
public struct JSONParseError: Error, Equatable, CustomStringConvertible, Sendable {
    public let message: String
    public let line: Int
    public let column: Int

    public var description: String { "\(message) (line \(line), column \(column))" }
}

extension JSONValue {
    /// Parses JSON text. Like Karabiner, `//` and `/* */` comments and a leading byte order mark are accepted;
    /// trailing commas are not.
    public static func parse(_ text: String) throws -> JSONValue {
        try parse(bytes: Array(text.utf8))
    }

    /// Parses UTF-8 data; invalid UTF-8 is an error.
    public static func parse(data: Data) throws -> JSONValue {
        guard String(data: data, encoding: .utf8) != nil else {
            throw JSONParseError(message: "The text is not valid UTF-8", line: 1, column: 1)
        }
        return try parse(bytes: Array(data))
    }

    /// True when `text` has comments outside of strings (Karabiner drops them the next time it saves).
    public static func containsComments(_ text: String) -> Bool {
        var parser = JSONParser(bytes: Array(text.utf8))
        return parser.scanForComments()
    }

    private static func parse(bytes: [UInt8]) throws -> JSONValue {
        var parser = JSONParser(bytes: bytes)
        return try parser.parseDocument()
    }
}

private struct JSONParser {
    static let maxDepth = 64

    let bytes: [UInt8]
    var index = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
    }

    // MARK: Errors

    func error(_ message: String, at position: Int? = nil) -> JSONParseError {
        let stop = min(position ?? index, bytes.count)
        var line = 1
        var lineStart = 0
        for offset in 0..<stop where bytes[offset] == 0x0A {
            line += 1
            lineStart = offset + 1
        }
        let column = String(decoding: bytes[lineStart..<stop], as: UTF8.self).count + 1
        return JSONParseError(message: message, line: line, column: column)
    }

    // MARK: Document

    mutating func parseDocument() throws -> JSONValue {
        try skipTrivia()
        guard index < bytes.count else { throw error("The text is empty") }
        let value = try parseValue(depth: 0)
        try skipTrivia()
        guard index == bytes.count else { throw error("Unexpected text after the value") }
        return value
    }

    mutating func scanForComments() -> Bool {
        while index < bytes.count {
            switch bytes[index] {
            case 0x22:
                if (try? parseString()) == nil { return false }
            case 0x2F where index + 1 < bytes.count && (bytes[index + 1] == 0x2F || bytes[index + 1] == 0x2A):
                return true
            default:
                index += 1
            }
        }
        return false
    }

    mutating func skipTrivia() throws {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D:
                index += 1
            case 0x2F:
                let start = index
                guard index + 1 < bytes.count else { throw error("Unexpected '/'") }
                if bytes[index + 1] == 0x2F {
                    index += 2
                    while index < bytes.count, bytes[index] != 0x0A { index += 1 }
                } else if bytes[index + 1] == 0x2A {
                    index += 2
                    while true {
                        guard index + 1 < bytes.count else { throw error("Unterminated comment", at: start) }
                        if bytes[index] == 0x2A, bytes[index + 1] == 0x2F { index += 2; break }
                        index += 1
                    }
                } else {
                    throw error("Unexpected '/'")
                }
            default:
                return
            }
        }
    }

    // MARK: Values

    mutating func parseValue(depth: Int) throws -> JSONValue {
        guard depth < Self.maxDepth else { throw error("The nesting is too deep") }
        guard index < bytes.count else { throw error("Unexpected end of text") }
        switch bytes[index] {
        case 0x7B: return try parseObject(depth: depth)
        case 0x5B: return try parseArray(depth: depth)
        case 0x22: return .string(try parseString())
        case 0x74: try expect("true"); return .bool(true)
        case 0x66: try expect("false"); return .bool(false)
        case 0x6E: try expect("null"); return .null
        case 0x2D, 0x30...0x39: return try parseNumber()
        default: throw error("Unexpected character")
        }
    }

    mutating func expect(_ word: String) throws {
        let utf8 = Array(word.utf8)
        guard index + utf8.count <= bytes.count, Array(bytes[index..<index + utf8.count]) == utf8 else {
            throw error("Unexpected character")
        }
        index += utf8.count
    }

    mutating func parseObject(depth: Int) throws -> JSONValue {
        index += 1
        var members: [JSONMember] = []
        try skipTrivia()
        if index < bytes.count, bytes[index] == 0x7D { index += 1; return .object(members) }
        while true {
            try skipTrivia()
            guard index < bytes.count, bytes[index] == 0x22 else { throw error("Expected a string key") }
            let key = try parseString()
            try skipTrivia()
            guard index < bytes.count, bytes[index] == 0x3A else { throw error("Expected ':'") }
            index += 1
            try skipTrivia()
            members.append(JSONMember(key, try parseValue(depth: depth + 1)))
            try skipTrivia()
            guard index < bytes.count else { throw error("Unterminated object") }
            if bytes[index] == 0x2C { index += 1; continue }
            if bytes[index] == 0x7D { index += 1; return .object(members) }
            throw error("Expected ',' or '}'")
        }
    }

    mutating func parseArray(depth: Int) throws -> JSONValue {
        index += 1
        var elements: [JSONValue] = []
        try skipTrivia()
        if index < bytes.count, bytes[index] == 0x5D { index += 1; return .array(elements) }
        while true {
            try skipTrivia()
            elements.append(try parseValue(depth: depth + 1))
            try skipTrivia()
            guard index < bytes.count else { throw error("Unterminated array") }
            if bytes[index] == 0x2C { index += 1; continue }
            if bytes[index] == 0x5D { index += 1; return .array(elements) }
            throw error("Expected ',' or ']'")
        }
    }

    mutating func parseNumber() throws -> JSONValue {
        let start = index
        func skipDigits(_ parser: inout JSONParser) -> Int {
            var count = 0
            while parser.index < parser.bytes.count, (0x30...0x39).contains(parser.bytes[parser.index]) {
                parser.index += 1
                count += 1
            }
            return count
        }
        if bytes[index] == 0x2D { index += 1 }
        guard index < bytes.count else { throw error("Invalid number", at: start) }
        if bytes[index] == 0x30 {
            index += 1
        } else if skipDigits(&self) == 0 {
            throw error("Invalid number", at: start)
        }
        if index < bytes.count, bytes[index] == 0x2E {
            index += 1
            if skipDigits(&self) == 0 { throw error("Invalid number", at: start) }
        }
        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
            index += 1
            if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
            if skipDigits(&self) == 0 { throw error("Invalid number", at: start) }
        }
        if index < bytes.count, (0x30...0x39).contains(bytes[index]) { throw error("Invalid number", at: start) }
        guard let number = JSONNumber(literal: String(decoding: bytes[start..<index], as: UTF8.self)) else {
            throw error("Invalid number", at: start)
        }
        return .number(number)
    }

    mutating func parseString() throws -> String {
        let start = index
        index += 1
        var output: [UInt8] = []
        while true {
            guard index < bytes.count else { throw error("Unterminated string", at: start) }
            let byte = bytes[index]
            switch byte {
            case 0x22:
                index += 1
                return String(decoding: output, as: UTF8.self)
            case 0x5C:
                try parseEscape(into: &output)
            case 0x00..<0x20:
                throw error("Control character in string")
            default:
                output.append(byte)
                index += 1
            }
        }
    }

    mutating func parseEscape(into output: inout [UInt8]) throws {
        index += 1
        guard index < bytes.count else { throw error("Unterminated string") }
        let escape = bytes[index]
        index += 1
        switch escape {
        case 0x22, 0x5C, 0x2F: output.append(escape)
        case 0x62: output.append(0x08)
        case 0x66: output.append(0x0C)
        case 0x6E: output.append(0x0A)
        case 0x72: output.append(0x0D)
        case 0x74: output.append(0x09)
        case 0x75:
            var scalarValue = try parseHex4()
            if (0xD800..<0xDC00).contains(scalarValue) {
                guard index + 1 < bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 else {
                    throw error("Unpaired surrogate")
                }
                index += 2
                let low = try parseHex4()
                guard (0xDC00..<0xE000).contains(low) else { throw error("Unpaired surrogate") }
                scalarValue = 0x10000 + ((scalarValue - 0xD800) << 10) + (low - 0xDC00)
            } else if (0xDC00..<0xE000).contains(scalarValue) {
                throw error("Unpaired surrogate")
            }
            guard let scalar = Unicode.Scalar(scalarValue) else { throw error("Invalid escape") }
            output.append(contentsOf: Array(String(Character(scalar)).utf8))
        default:
            throw error("Invalid escape", at: index - 1)
        }
    }

    mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw error("Invalid \\u escape") }
        var result: UInt32 = 0
        for offset in 0..<4 {
            let byte = bytes[index + offset]
            let digit: UInt32
            switch byte {
            case 0x30...0x39: digit = UInt32(byte - 0x30)
            case 0x41...0x46: digit = UInt32(byte - 0x41 + 10)
            case 0x61...0x66: digit = UInt32(byte - 0x61 + 10)
            default: throw error("Invalid \\u escape", at: index + offset)
            }
            result = result << 4 | digit
        }
        index += 4
        return result
    }
}
