import Foundation

extension JSONValue {
    /// Karabiner-Elements' own layout: four-space indent; arrays stay on one line unless they hold two or more
    /// containers or a multi-line value; objects with a single single-line member stay on one line; no trailing newline.
    public func serialized() -> String {
        var output = ""
        JSONWriter.write(self, parentKey: nil, level: 0, into: &output)
        return output
    }
}

private enum JSONWriter {
    /// Karabiner always spreads these arrays over several lines.
    static let forcedMultiLineKeys: Set<String> = [
        "bundle_identifiers", "description_notes",
        "game_pad_stick_horizontal_wheel_formula", "game_pad_stick_vertical_wheel_formula",
        "game_pad_stick_x_formula", "game_pad_stick_y_formula",
    ]

    static func isMultiLine(_ value: JSONValue, parentKey: String?) -> Bool {
        switch value {
        case .object(let members):
            if members.isEmpty { return false }
            if members.count == 1 { return isMultiLine(members[0].value, parentKey: members[0].key) }
            return true
        case .array(let elements):
            if let parentKey, forcedMultiLineKeys.contains(parentKey) { return true }
            if elements.isEmpty { return false }
            if elements.count == 1 { return isMultiLine(elements[0], parentKey: nil) }
            return elements.contains { $0.isObject || $0.isArray }
        default:
            return false
        }
    }

    static func indent(_ level: Int, into output: inout String) {
        output.append(String(repeating: " ", count: 4 * level))
    }

    static func write(_ value: JSONValue, parentKey: String?, level: Int, into output: inout String) {
        switch value {
        case .null: output.append("null")
        case .bool(let flag): output.append(flag ? "true" : "false")
        case .number(let number): output.append(number.literal)
        case .string(let text): writeString(text, into: &output)
        case .object(let members):
            if members.isEmpty {
                output.append("{}")
            } else if !isMultiLine(value, parentKey: parentKey) {
                output.append("{ ")
                writeString(members[0].key, into: &output)
                output.append(": ")
                write(members[0].value, parentKey: members[0].key, level: level + 1, into: &output)
                output.append(" }")
            } else {
                output.append("{\n")
                for (position, member) in members.enumerated() {
                    if position > 0 { output.append(",\n") }
                    indent(level + 1, into: &output)
                    writeString(member.key, into: &output)
                    output.append(": ")
                    write(member.value, parentKey: member.key, level: level + 1, into: &output)
                }
                output.append("\n")
                indent(level, into: &output)
                output.append("}")
            }
        case .array(let elements):
            if !isMultiLine(value, parentKey: parentKey) {
                output.append("[")
                for (position, element) in elements.enumerated() {
                    if position > 0 { output.append(", ") }
                    write(element, parentKey: nil, level: level + 1, into: &output)
                }
                output.append("]")
            } else {
                output.append("[\n")
                for (position, element) in elements.enumerated() {
                    if position > 0 { output.append(",\n") }
                    indent(level + 1, into: &output)
                    write(element, parentKey: nil, level: level + 1, into: &output)
                }
                output.append("\n")
                indent(level, into: &output)
                output.append("]")
            }
        }
    }

    static func writeString(_ text: String, into output: inout String) {
        output.append("\"")
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output.append("\\\"")
            case "\\": output.append("\\\\")
            case "\u{8}": output.append("\\b")
            case "\u{c}": output.append("\\f")
            case "\n": output.append("\\n")
            case "\r": output.append("\\r")
            case "\t": output.append("\\t")
            default:
                if scalar.value < 0x20 {
                    output.append("\\u" + String(format: "%04x", scalar.value))
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output.append("\"")
    }
}
