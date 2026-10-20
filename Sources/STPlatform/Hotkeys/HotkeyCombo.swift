import Foundation

/// Why a key combination cannot be used as a global hotkey.
public enum HotkeyComboIssue: Hashable, Sendable {
    /// The key is not one sTools knows (modifier keys, media keys, or a code outside the table).
    case unsupportedKey
    /// No modifier at all on a key that is not F1 to F20.
    case needsModifier
    /// Only Shift and/or Option: those are how people type and move through text, so a hotkey on them
    /// would break typing in every app.
    case needsCommandOrControl
    /// macOS (or nearly every app) already owns this combination. The text names what it does.
    case reserved(String)
}

/// A key plus modifiers, in Carbon terms: `keyCode` is a virtual key code (`kVK_*`, position on the
/// keyboard, not a character) and `modifiers` use the Carbon bit values that `RegisterEventHotKey` takes.
public struct HotkeyCombo: Codable, Hashable, Sendable {
    /// Modifier keys with the Carbon values (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 8)
        public static let shift = Modifiers(rawValue: 1 << 9)
        public static let option = Modifiers(rawValue: 1 << 11)
        public static let control = Modifiers(rawValue: 1 << 12)
        public static let all: Modifiers = [.command, .shift, .option, .control]
    }

    public let keyCode: UInt16
    public let modifiers: Modifiers

    /// Bits outside the four modifiers are dropped.
    public init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(.all)
    }

    /// Builds a combo from raw numbers, the form `STShortcut` in STDesign carries.
    public init(keyCode: UInt16, modifierRawValue: UInt32) {
        self.init(keyCode: keyCode, modifiers: Modifiers(rawValue: modifierRawValue))
    }

    private enum CodingKeys: String, CodingKey { case keyCode, modifiers }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(keyCode: try container.decode(UInt16.self, forKey: .keyCode),
                  modifiers: try container.decode(Modifiers.self, forKey: .modifiers))
    }

    // MARK: Display

    /// macOS style: modifiers in the order ⌃⌥⇧⌘, then the key. "⌃⌥C", "⇧F5", "⌘Space".
    public var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + (Self.keys[keyCode]?.name ?? "Key \(keyCode)")
    }

    // MARK: Validation

    /// Whether the key is one of F1 to F20.
    public var isFunctionKey: Bool { Self.keys[keyCode]?.isFunction ?? false }

    /// The first reason this combination cannot be a hotkey, or nil when it can.
    public var issue: HotkeyComboIssue? {
        guard Self.keys[keyCode] != nil else { return .unsupportedKey }
        if !isFunctionKey {
            if modifiers.isEmpty { return .needsModifier }
            if modifiers.isDisjoint(with: [.command, .control]) { return .needsCommandOrControl }
        }
        if let reason = Self.reservedReason[self] { return .reserved(reason) }
        return nil
    }

    public var isValid: Bool { issue == nil }

    // MARK: Tables

    private struct Key {
        let name: String
        var isFunction = false
    }

    private static let keys: [UInt16: Key] = {
        var table: [UInt16: Key] = [:]
        let letters: [(UInt16, String)] = [
            (0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"), (5, "G"), (4, "H"), (34, "I"),
            (38, "J"), (40, "K"), (37, "L"), (46, "M"), (45, "N"), (31, "O"), (35, "P"), (12, "Q"),
            (15, "R"), (1, "S"), (17, "T"), (32, "U"), (9, "V"), (13, "W"), (7, "X"), (16, "Y"), (6, "Z"),
        ]
        let digits: [(UInt16, String)] = [
            (29, "0"), (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"), (22, "6"), (26, "7"), (28, "8"), (25, "9"),
        ]
        let punctuation: [(UInt16, String)] = [
            (27, "-"), (24, "="), (33, "["), (30, "]"), (42, "\\"), (41, ";"), (39, "'"), (43, ","),
            (47, "."), (44, "/"), (50, "`"),
        ]
        let keypad: [(UInt16, String)] = [
            (82, "Pad 0"), (83, "Pad 1"), (84, "Pad 2"), (85, "Pad 3"), (86, "Pad 4"), (87, "Pad 5"),
            (88, "Pad 6"), (89, "Pad 7"), (91, "Pad 8"), (92, "Pad 9"), (65, "Pad ."), (67, "Pad *"),
            (69, "Pad +"), (75, "Pad /"), (78, "Pad -"), (81, "Pad ="), (76, "Pad Enter"),
        ]
        let editing: [(UInt16, String)] = [
            (36, "↩"), (48, "⇥"), (49, "Space"), (51, "⌫"), (53, "⎋"), (117, "⌦"),
            (123, "←"), (124, "→"), (125, "↓"), (126, "↑"),
            (115, "↖"), (119, "↘"), (116, "⇞"), (121, "⇟"), (114, "Help"),
        ]
        for (code, name) in letters + digits + punctuation + keypad + editing { table[code] = Key(name: name) }
        let functionCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for (index, code) in functionCodes.enumerated() { table[code] = Key(name: "F\(index + 1)", isFunction: true) }
        return table
    }()

    /// Combinations macOS or every app already claims. `RegisterEventHotKey` refuses many of them
    /// anyway, but a clear message beats a silent failure. Each entry reads: combination, what it does.
    static let reservedCombos: [(combo: HotkeyCombo, reason: String)] = {
        let cmd = Modifiers.command, shift = Modifiers.shift, option = Modifiers.option, control = Modifiers.control
        return [
            (HotkeyCombo(keyCode: 12, modifiers: cmd), "Quit"),
            (HotkeyCombo(keyCode: 12, modifiers: [cmd, shift]), "Log out"),
            (HotkeyCombo(keyCode: 12, modifiers: [cmd, control]), "Lock screen"),
            (HotkeyCombo(keyCode: 53, modifiers: [cmd, option]), "Force quit"),
            (HotkeyCombo(keyCode: 48, modifiers: cmd), "App switcher"),
            (HotkeyCombo(keyCode: 48, modifiers: [cmd, shift]), "App switcher"),
            (HotkeyCombo(keyCode: 50, modifiers: cmd), "Window switcher"),
            (HotkeyCombo(keyCode: 50, modifiers: [cmd, shift]), "Window switcher"),
            (HotkeyCombo(keyCode: 49, modifiers: cmd), "Spotlight"),
            (HotkeyCombo(keyCode: 49, modifiers: [cmd, option]), "Finder search"),
            (HotkeyCombo(keyCode: 49, modifiers: control), "Input source"),
            (HotkeyCombo(keyCode: 49, modifiers: [cmd, control]), "Emoji picker"),
            (HotkeyCombo(keyCode: 4, modifiers: cmd), "Hide app"),
            (HotkeyCombo(keyCode: 4, modifiers: [cmd, option]), "Hide others"),
            (HotkeyCombo(keyCode: 46, modifiers: cmd), "Minimize"),
            (HotkeyCombo(keyCode: 20, modifiers: [cmd, shift]), "Screenshot"),
            (HotkeyCombo(keyCode: 21, modifiers: [cmd, shift]), "Screenshot"),
            (HotkeyCombo(keyCode: 23, modifiers: [cmd, shift]), "Screenshot"),
            (HotkeyCombo(keyCode: 123, modifiers: control), "Move to the previous Space"),
            (HotkeyCombo(keyCode: 124, modifiers: control), "Move to the next Space"),
            (HotkeyCombo(keyCode: 126, modifiers: control), "Mission Control"),
            (HotkeyCombo(keyCode: 125, modifiers: control), "App windows"),
        ]
    }()

    private static let reservedReason: [HotkeyCombo: String] =
        Dictionary(uniqueKeysWithValues: reservedCombos.map { ($0.combo, $0.reason) })
}
