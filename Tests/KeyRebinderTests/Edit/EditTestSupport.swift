import Foundation
@testable import KeyRebinder

enum TestConfig {
    static func fixture(_ name: String) -> JSONValue {
        do { return try JSONValue.parse(FixtureLoader.text(name)) } catch { fatalError("bad fixture \(name): \(error)") }
    }

    static func parse(_ text: String) -> JSONValue {
        do { return try JSONValue.parse(text) } catch { fatalError("bad test JSON: \(error)") }
    }

    /// One profile named "P" with the given pieces of JSON text.
    static func profile(
        simple: String? = nil, devices: String? = nil, rules: String? = nil, fn: String? = nil
    ) -> JSONValue {
        var members = ["\"name\": \"P\"", "\"selected\": true"]
        if let simple { members.append("\"simple_modifications\": \(simple)") }
        if let devices { members.append("\"devices\": \(devices)") }
        if let fn { members.append("\"fn_function_keys\": \(fn)") }
        if let rules { members.append("\"complex_modifications\": { \"rules\": \(rules) }") }
        return parse("{ \"profiles\": [{ \(members.joined(separator: ", ")) }] }")
    }

    static func pair(_ from: String, _ to: String) -> String {
        "{ \"from\": { \"key_code\": \"\(from)\" }, \"to\": [{ \"key_code\": \"\(to)\" }] }"
    }

    /// A basic manipulator turning one key into another.
    static func swap(_ from: String, _ to: String) -> String {
        "{ \"type\": \"basic\", \"from\": { \"key_code\": \"\(from)\" }, \"to\": [{ \"key_code\": \"\(to)\" }] }"
    }

    static func rule(_ description: String, _ manipulators: String...) -> String {
        "{ \"description\": \"\(description)\", \"manipulators\": [\(manipulators.joined(separator: ", "))] }"
    }

    static let keyboard = DeviceIdentifiers(vendorID: 1452, productID: 834, isKeyboard: true)
    static let mouse = DeviceIdentifiers(vendorID: 1133, productID: 49271, isPointingDevice: true)
}

/// The paths at which two trees differ, e.g. `profiles[0].simple_modifications`. Arrays compare by position and
/// stop at the first differing level, so an appended element reports the array itself.
func changedPaths(_ before: JSONValue, _ after: JSONValue, path: String = "") -> [String] {
    if before == after { return [] }
    switch (before, after) {
    case (.object(let old), .object(let new)):
        let keys = (old.map(\.key) + new.map(\.key)).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return keys.flatMap { key -> [String] in
            let child = path.isEmpty ? key : "\(path).\(key)"
            switch (before[key], after[key]) {
            case (let old?, let new?): return changedPaths(old, new, path: child)
            default: return [child]
            }
        }
    case (.array(let old), .array(let new)) where old.count == new.count:
        return zip(old, new).enumerated().flatMap { index, pair in changedPaths(pair.0, pair.1, path: "\(path)[\(index)]") }
    default:
        return [path]
    }
}
