import Foundation

/// A JSON number kept as its exact source text, so big integers and `1.0` versus `1` survive a round trip.
public struct JSONNumber: Hashable, Sendable {
    /// The number exactly as written; always valid JSON number syntax.
    public let literal: String

    /// Wraps `literal` when it is valid JSON number syntax.
    public init?(literal: String) {
        guard Self.isValid(literal) else { return nil }
        self.literal = literal
    }

    public init(_ value: Int) { literal = String(value) }

    /// Finite values only; non-finite values are written as 0 because JSON cannot express them.
    public init(_ value: Double) {
        guard value.isFinite else { literal = "0"; return }
        if value == value.rounded(), abs(value) < 1e15 {
            literal = String(format: "%.1f", value)
        } else {
            literal = "\(value)"
        }
    }

    public var isInteger: Bool { !literal.contains(where: { ".eE".contains($0) }) }
    public var intValue: Int? { isInteger ? Int(literal) : nil }
    public var doubleValue: Double { Double(literal) ?? 0 }

    /// True when both numbers have the same numeric value (`1` equals `1.0`).
    public func numericallyEquals(_ other: JSONNumber) -> Bool {
        if literal == other.literal { return true }
        if isInteger, other.isInteger { return false }
        return doubleValue == other.doubleValue
    }

    private static func isValid(_ text: String) -> Bool {
        var scanner = Array(text.utf8)[...]
        func digits() -> Int {
            var count = 0
            while let byte = scanner.first, byte >= 0x30, byte <= 0x39 { scanner.removeFirst(); count += 1 }
            return count
        }
        if scanner.first == 0x2D { scanner.removeFirst() }
        guard let first = scanner.first else { return false }
        if first == 0x30 {
            scanner.removeFirst()
        } else if digits() == 0 {
            return false
        }
        if scanner.first == 0x2E {
            scanner.removeFirst()
            if digits() == 0 { return false }
        }
        if scanner.first == 0x65 || scanner.first == 0x45 {
            scanner.removeFirst()
            if scanner.first == 0x2B || scanner.first == 0x2D { scanner.removeFirst() }
            if digits() == 0 { return false }
        }
        return scanner.isEmpty
    }
}

/// One `"key": value` pair of a JSON object.
public struct JSONMember: Hashable, Sendable {
    public var key: String
    public var value: JSONValue

    public init(_ key: String, _ value: JSONValue) {
        self.key = key
        self.value = value
    }
}

/// An order-preserving JSON tree. Objects are ordered lists of members (duplicate keys are kept as read),
/// so parsing then serializing never reorders or drops anything. `==` is strict: order and number text count.
/// Use `semanticallyEquals` to compare ignoring object member order.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(JSONNumber)
    case string(String)
    case array([JSONValue])
    case object([JSONMember])

    public static func int(_ value: Int) -> JSONValue { .number(JSONNumber(value)) }
    public static func double(_ value: Double) -> JSONValue { .number(JSONNumber(value)) }
    public static var emptyObject: JSONValue { .object([]) }
    public static var emptyArray: JSONValue { .array([]) }

    // MARK: Reading

    public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    public var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var numberValue: JSONNumber? { if case .number(let value) = self { value } else { nil } }
    public var intValue: Int? { numberValue?.intValue }
    public var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    public var members: [JSONMember]? { if case .object(let value) = self { value } else { nil } }
    public var isObject: Bool { members != nil }
    public var isArray: Bool { arrayValue != nil }
    public var isNull: Bool { if case .null = self { true } else { false } }

    /// The value of the first member named `key` (objects only).
    public subscript(key: String) -> JSONValue? {
        members?.first { $0.key == key }?.value
    }

    /// The element at `index` (arrays only); `nil` when out of range.
    public subscript(index index: Int) -> JSONValue? {
        guard let elements = arrayValue, elements.indices.contains(index) else { return nil }
        return elements[index]
    }

    // MARK: Pure updates

    /// Returns a copy with the first member named `key` set to `value` (kept in place), or appended when absent.
    /// Passing `nil` removes the first member with that key. Non-objects are returned unchanged.
    public func setting(_ key: String, _ value: JSONValue?) -> JSONValue {
        guard case .object(var items) = self else { return self }
        let index = items.firstIndex { $0.key == key }
        switch (index, value) {
        case (let index?, let value?): items[index].value = value
        case (let index?, nil): items.remove(at: index)
        case (nil, let value?): items.append(JSONMember(key, value))
        case (nil, nil): break
        }
        return .object(items)
    }

    /// Returns a copy with `transform` applied to the first member named `key` (`nil` input when missing;
    /// returning `nil` removes it).
    public func updating(_ key: String, _ transform: (JSONValue?) -> JSONValue?) -> JSONValue {
        setting(key, transform(self[key]))
    }

    /// Returns a copy with the element at `index` replaced. Out-of-range indexes and non-arrays are unchanged.
    public func replacing(at index: Int, with value: JSONValue) -> JSONValue {
        guard case .array(var elements) = self, elements.indices.contains(index) else { return self }
        elements[index] = value
        return .array(elements)
    }

    /// Returns a copy with `value` appended (arrays only).
    public func appending(_ value: JSONValue) -> JSONValue {
        guard case .array(var elements) = self else { return self }
        elements.append(value)
        return .array(elements)
    }

    /// Returns a copy with the element at `index` removed (arrays only).
    public func removing(at index: Int) -> JSONValue {
        guard case .array(var elements) = self, elements.indices.contains(index) else { return self }
        elements.remove(at: index)
        return .array(elements)
    }

    // MARK: Comparison

    /// Equality that ignores object member order and compares numbers by value.
    public func semanticallyEquals(_ other: JSONValue) -> Bool {
        switch (self, other) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.number(let a), .number(let b)): return a.numericallyEquals(b)
        case (.array(let a), .array(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.semanticallyEquals($1) }
        case (.object(let a), .object(let b)):
            guard a.count == b.count else { return false }
            var remaining = b
            for member in a {
                guard let match = remaining.firstIndex(where: { $0.key == member.key && $0.value.semanticallyEquals(member.value) }) else {
                    return false
                }
                remaining.remove(at: match)
            }
            return true
        default: return false
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(JSONNumber(value)) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(nilLiteral: ()) { self = .null }
    /// Members keep the order they are written in.
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(elements.map { JSONMember($0.0, $0.1) })
    }
}
