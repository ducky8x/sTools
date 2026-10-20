// Generates Sources/KeyRebinder/Resources/KeyTable.json from a Karabiner-Elements source checkout.
//
// Usage: swift scripts/generate-key-table.swift <karabiner-elements-checkout> [outputFile]
//
// Inputs (all under the checkout):
//   src/apps/SettingsWindow/Resources/simple_modifications.json   the canonical list of keys, consumer keys,
//                                                                  pointing buttons and the other event kinds
//   src/apps/localization/Resources/settings/key_picker.json       English labels for the localized entries
//   src/share/types/momentary_switch_event_details/key_code.hpp    key_code name -> HID usage name
//   vendor/vendor/include/pqrs/osx/cg_event/key_code.hpp            HID usage name -> macOS virtual key code
//   version                                                        recorded in the output
//
// The output is deterministic: entries keep Karabiner's own order, object keys are sorted (as Karabiner
// writes them), and nothing depends on the machine or the time. The default output path is
// Sources/KeyRebinder/Resources/KeyTable.json next to this script's package root.

import Foundation

struct GeneratorError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: Reading

func readText(_ url: URL) throws -> String {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw GeneratorError("cannot read \(url.path)") }
    return text
}

func readJSON(_ url: URL) throws -> Any {
    guard let data = try? Data(contentsOf: url), let value = try? JSONSerialization.jsonObject(with: data) else {
        throw GeneratorError("cannot parse \(url.path)")
    }
    return value
}

func matches(_ pattern: String, in text: String) throws -> [[String]] {
    let expression = try NSRegularExpression(pattern: pattern)
    let range = NSRange(text.startIndex..., in: text)
    return expression.matches(in: text, range: range).map { match in
        (1..<match.numberOfRanges).map { String(text[Range(match.range(at: $0), in: text)!]) }
    }
}

// MARK: JSON output

func quoted(_ text: String) -> String {
    var output = "\""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": output += "\\\""
        case "\\": output += "\\\\"
        case "\n": output += "\\n"
        case "\t": output += "\\t"
        case "\r": output += "\\r"
        default:
            if scalar.value < 0x20 {
                output += String(format: "\\u%04x", scalar.value)
            } else {
                output.unicodeScalars.append(scalar)
            }
        }
    }
    return output + "\""
}

/// Compact JSON with sorted object keys; floating-point numbers keep a decimal point (`2.0`, not `2`).
func compact(_ value: Any) throws -> String {
    switch value {
    case let text as String:
        return quoted(text)
    case let number as NSNumber:
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
        if CFNumberIsFloatType(number) {
            let double = number.doubleValue
            return double == double.rounded() ? String(format: "%.1f", double) : "\(double)"
        }
        return number.stringValue
    case let array as [Any]:
        return "[" + (try array.map(compact)).joined(separator: ",") + "]"
    case let object as [String: Any]:
        let members = try object.keys.sorted().map { key in "\(quoted(key)):\(try compact(object[key]!))" }
        return "{" + members.joined(separator: ",") + "}"
    default:
        throw GeneratorError("unsupported JSON value \(value)")
    }
}

// MARK: Virtual key codes

/// Maps every key_code name Karabiner knows to the macOS virtual key code (kVK_*) Karabiner itself uses for it.
func virtualKeyCodes(root: URL) throws -> [String: Int] {
    let keyCodeHeader = try readText(root.appending(path: "src/share/types/momentary_switch_event_details/key_code.hpp"))
    let cgHeader = try readText(root.appending(path: "vendor/vendor/include/pqrs/osx/cg_event/key_code.hpp"))

    var symbolValues: [String: Int] = [:]
    for match in try matches(#"constexpr value_t (\w+)\(0x([0-9a-fA-F]+)\);"#, in: cgHeader) {
        symbolValues[match[0]] = Int(match[1], radix: 16)
    }

    let mapPrefixes = [
        "usage_page_keyboard_or_keypad_map": "",
        "usage_page_consumer_map": "consumer_",
        "usage_page_apple_vendor_keyboard_map": "apple_vendor_keyboard_",
        "usage_page_apple_vendor_top_case_map": "apple_vendor_top_case_",
        "usage_page_generic_desktop_map": "generic_desktop_",
    ]
    var mapped: [String: Int] = [:]
    for (mapName, prefix) in mapPrefixes {
        guard let start = cgHeader.range(of: "constexpr auto \(mapName)"),
              let end = cgHeader.range(of: "});", range: start.upperBound..<cgHeader.endIndex) else {
            throw GeneratorError("missing \(mapName) in cg_event/key_code.hpp")
        }
        let section = String(cgHeader[start.upperBound..<end.lowerBound])
        for line in section.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
            for match in try matches(#"PQRS_OSX_CG_EVENT_KEY_CODE_PAIR\((\w+)\)"#, in: String(line)) {
                let usageName = match[0]
                guard let value = symbolValues[prefix + usageName] ?? symbolValues[usageName] else {
                    throw GeneratorError("no value for \(prefix + usageName)")
                }
                mapped[prefix + usageName] = value
            }
        }
    }

    var codes: [String: Int] = [:]
    for match in try matches(#"\{"(\w+)", pqrs::hid::usage::keyboard_or_keypad::(\w+)\}"#, in: keyCodeHeader) {
        if let value = mapped[match[1]] { codes[match[0]] = value }
    }
    let pagePrefixes = [
        "apple_vendor_keyboard": "apple_vendor_keyboard_",
        "apple_vendor_top_case": "apple_vendor_top_case_",
        "consumer": "consumer_",
        "generic_desktop": "generic_desktop_",
    ]
    for match in try matches(#"\{"(\w+)", pqrs::hid::usage_pair\(pqrs::hid::usage_page::(\w+), pqrs::hid::usage::\w+::(\w+)\)\}"#, in: keyCodeHeader) {
        guard let prefix = pagePrefixes[match[1]], let value = mapped[prefix + match[2]] else { continue }
        codes[match[0]] = value
    }
    return codes
}

// MARK: Main

func run() throws {
    let arguments = CommandLine.arguments
    guard arguments.count >= 2 else {
        throw GeneratorError("usage: swift scripts/generate-key-table.swift <karabiner-elements-checkout> [outputFile]")
    }
    let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let output = arguments.count >= 3
        ? URL(fileURLWithPath: arguments[2])
        : packageRoot.appending(path: "Sources/KeyRebinder/Resources/KeyTable.json")

    let version = try readText(root.appending(path: "version")).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let rows = try readJSON(root.appending(path: "src/apps/SettingsWindow/Resources/simple_modifications.json")) as? [[String: Any]],
          let english = try readJSON(root.appending(path: "src/apps/localization/Resources/settings/key_picker.json")) as? [String: [String: String]]
    else { throw GeneratorError("unexpected simple_modifications.json or key_picker.json shape") }

    func text(_ row: [String: Any], plain: String, localized: String) throws -> String {
        if let value = row[plain] as? String { return value }
        if let key = row[localized] as? String {
            guard let value = english[key]?["en"] else { throw GeneratorError("no English text for \(key)") }
            return value
        }
        throw GeneratorError("entry has neither \(plain) nor \(localized): \(row)")
    }

    var categories: [(id: String, title: String)] = []
    var keyLines: [String] = []
    var orderedKeyCodes: [String] = []
    for row in rows {
        if let key = row["category_localization_key"] as? String {
            guard let title = english[key]?["en"] else { throw GeneratorError("no English text for \(key)") }
            categories.append((String(key.split(separator: ".").last!), title))
            continue
        }
        guard let category = categories.last?.id else { throw GeneratorError("entry before the first category") }
        guard let events = row["data"] as? [Any], !events.isEmpty else { throw GeneratorError("entry without data: \(row)") }
        let label = try text(row, plain: "label", localized: "label_localization_key")
        var members = [
            "\"category\":\(quoted(category))",
            "\"events\":\(try compact(events))",
            "\"label\":\(quoted(label))",
        ]
        if row["not_from"] as? Bool == true { members.append("\"noFrom\":true") }
        if row["not_to"] as? Bool == true { members.append("\"noTo\":true") }
        if row["unsafe_from"] as? Bool == true { members.append("\"unsafeFrom\":true") }
        keyLines.append("    {" + members.joined(separator: ",") + "}")

        if events.count == 1, let event = events[0] as? [String: Any], let code = event["key_code"] as? String,
           !orderedKeyCodes.contains(code) {
            orderedKeyCodes.append(code)
        }
    }

    // Several key_code names can share one virtual key code (left_option / left_alt, f13 / print_screen...).
    // The first one in Karabiner's own picker order is the primary: it is the name the key tester shows
    // (the "vk_" compatibility aliases always come last).
    let codes = try virtualKeyCodes(root: root)
    var groups: [Int: [String]] = [:]
    for code in orderedKeyCodes.filter({ !$0.hasPrefix("vk_") }) + orderedKeyCodes.filter({ $0.hasPrefix("vk_") }) {
        if let value = codes[code] { groups[value, default: []].append(code) }
    }
    let virtualLines = groups.keys.sorted().map { value in
        "    {\"keyCodes\":\(try! compact(groups[value]!)),\"vk\":\(value)}"
    }

    let categoryLines = categories.map { "    {\"id\":\(quoted($0.id)),\"title\":\(quoted($0.title))}" }
    let document = """
    {
      "format": 1,
      "source": \(quoted("Karabiner-Elements \(version): simple_modifications.json, key_picker.json, key_code.hpp, cg_event/key_code.hpp")),
      "categories": [
    \(categoryLines.joined(separator: ",\n"))
      ],
      "keys": [
    \(keyLines.joined(separator: ",\n"))
      ],
      "virtualKeys": [
    \(virtualLines.joined(separator: ",\n"))
      ]
    }

    """
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try document.write(to: output, atomically: true, encoding: .utf8)
    print("wrote \(keyLines.count) keys, \(categories.count) categories, \(groups.count) virtual key codes to \(output.path)")
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
