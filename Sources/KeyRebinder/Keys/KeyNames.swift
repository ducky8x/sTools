/// Short English names for events, as the plate, the editor and the checker's messages show them
/// ("Caps Lock", "Shift+F3", "Right Click"). Karabiner's own picker labels are raw codes.
public enum KeyNames {
    public static func name(for event: KarabinerEvent, table: KeyTable = .shared) -> String {
        switch event {
        case .key(let code):
            return keyName(code, table: table)
        case .pointing(let code):
            return pointingName(code)
        case .consumer(let code):
            return spaced(table.entry(for: event)?.label ?? code)
        case .other(.array(let items)):
            return items.isEmpty ? "nothing" : items.map { name(forEventObject: $0, table: table) }.joined(separator: ", ")
        case .other(let value):
            return name(forEventObject: value, table: table)
        }
    }

    /// One event object, with any `modifiers` written in front: `{"key_code": "f3", "modifiers": ["left_shift"]}`
    /// is "Left Shift+F3".
    static func name(forEventObject object: JSONValue, table: KeyTable) -> String {
        guard let members = object.members else { return object.serialized() }
        let eventMembers = members.filter { KarabinerEvent.plainEventKeys.contains($0.key) }
        guard eventMembers.count == 1 else { return table.label(for: .other(object)) }
        let core = KarabinerEvent(json: .object(eventMembers))
        let coreName: String
        switch core {
        case .other(let value): coreName = table.entry(for: core).map { spaced($0.label) } ?? value.serialized()
        default: coreName = name(for: core, table: table)
        }
        let modifiers = modifierCodes(object["modifiers"]).map { keyName($0, table: table) }
        return (modifiers + [coreName]).joined(separator: "+")
    }

    /// The codes of a `to` event's `modifiers`, which Karabiner accepts as one string or an array.
    static func modifierCodes(_ value: JSONValue?) -> [String] {
        switch value {
        case .string(let code)?: [code]
        case .array(let items)?: items.compactMap(\.stringValue)
        default: []
        }
    }

    private static func keyName(_ code: String, table: KeyTable) -> String {
        if let known = keyNames[code] { return known }
        for alias in table.aliases(of: .key(code)).dropFirst() {
            if case .key(let other) = alias, let known = keyNames[other] { return known }
        }
        if code.count == 1 { return code.uppercased() }
        if code.hasPrefix("f"), let number = Int(code.dropFirst()), (1...24).contains(number) { return "F\(number)" }
        if code.hasPrefix("keypad_") { return "Keypad " + spaced(String(code.dropFirst("keypad_".count))) }
        return spaced(code)
    }

    private static func pointingName(_ code: String) -> String {
        switch code {
        case "button1": "Left Click"
        case "button2": "Right Click"
        case "button3": "Middle Click"
        default:
            if let number = Int(code.dropFirst("button".count)), code.hasPrefix("button") { "Mouse Button \(number)" } else { spaced(code) }
        }
    }

    /// `volume_increment` → "Volume increment".
    private static func spaced(_ text: String) -> String {
        let words = text.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private static let keyNames: [String: String] = [
        "escape": "Esc", "tab": "Tab", "caps_lock": "Caps Lock", "spacebar": "Space", "return_or_enter": "Return",
        "delete_or_backspace": "Delete", "delete_forward": "Forward Delete", "fn": "fn",
        "left_shift": "Left Shift", "right_shift": "Right Shift", "left_control": "Left Control",
        "right_control": "Right Control", "left_option": "Left Option", "right_option": "Right Option",
        "left_command": "Left Command", "right_command": "Right Command",
        "up_arrow": "Up Arrow", "down_arrow": "Down Arrow", "left_arrow": "Left Arrow", "right_arrow": "Right Arrow",
        "home": "Home", "end": "End", "page_up": "Page Up", "page_down": "Page Down",
        "grave_accent_and_tilde": "`", "hyphen": "-", "equal_sign": "=", "open_bracket": "[", "close_bracket": "]",
        "backslash": "\\", "non_us_backslash": "§", "non_us_pound": "#", "semicolon": ";", "quote": "'",
        "comma": ",", "period": ".", "slash": "/",
        "japanese_eisuu": "英数", "japanese_kana": "かな", "international1": "_", "international3": "¥",
        "keypad_enter": "Keypad Enter", "keypad_num_lock": "Keypad Clear", "keypad_period": "Keypad .",
        "keypad_slash": "Keypad /", "keypad_asterisk": "Keypad *", "keypad_hyphen": "Keypad -",
        "keypad_plus": "Keypad +", "keypad_equal_sign": "Keypad =",
        "vk_none": "Nothing (disabled)",
    ]
}
