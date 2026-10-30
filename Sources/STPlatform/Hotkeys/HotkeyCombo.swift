import Foundation

/// Why a key combination cannot be used as a global hotkey. Any key sTools knows works, alone or with any mix
/// of ⌃ ⌥ ⇧ ⌘; only keys macOS can't register and combinations macOS keeps are refused. Everything else a
/// combination may do (take a typing key, a Minecraft key) is a note, never a refusal.
public enum HotkeyComboIssue: Hashable, Sendable {
    /// The key is not one sTools knows: a modifier key, Caps Lock, fn, a media or system key, or any other code
    /// outside the table.
    case unsupportedKey
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

    /// What a key is for, which decides the notes the hotkey editors show.
    public enum KeyKind: Hashable, Sendable {
        /// Letters, digits, punctuation, Space, Return, Tab, Delete, Forward Delete, Esc, the arrows, Home, End,
        /// Page Up, Page Down, every keypad key, 英数 and かな: keys people type and edit with.
        case typing
        /// F1 to F20.
        case function
        /// Help and Menu.
        case other
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

    /// The key that types `character` ("1", ",", "[": a digit or punctuation key, named as `keyName` names it) with
    /// `modifiers`, which is how the app names its menu shortcuts. Nil for a character no supported key carries.
    public init?(character: Character, modifiers: Modifiers) {
        guard let keyCode = Self.keys.first(where: { $0.value.name == String(character) })?.key else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers)
    }

    private enum CodingKeys: String, CodingKey { case keyCode, modifiers }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(keyCode: try container.decode(UInt16.self, forKey: .keyCode),
                  modifiers: try container.decode(Modifiers.self, forKey: .modifiers))
    }

    // MARK: Held modifiers

    /// The same key with ⇧ and/or ⌃ added to what is held, in the order ⇧, ⌃, ⇧⌃: the combinations a hotkey that also
    /// fires while holding Shift or Control registers too, because macOS matches modifiers exactly (spec 6.1). One that
    /// holds ⇧ gains only ⌃, one that holds ⌃ only ⇧, and one that holds both has none.
    public var shiftAndControlVariants: [HotkeyCombo] {
        let missing: [Modifiers] = [.shift, .control].filter { !modifiers.contains($0) }
        let added: [Modifiers] = missing.count == 2 ? [.shift, .control, [.shift, .control]] : missing
        return added.map { HotkeyCombo(keyCode: keyCode, modifiers: modifiers.union($0)) }
    }

    // MARK: Display

    /// macOS style: modifiers in the order ⌃⌥⇧⌘, then the key. "⌃⌥C", "⇧F5", "⌘Space", "Pad 1".
    public var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + keyName
    }

    /// The key alone, without its modifiers: "C", "F5", "Pad 1", "↩". A code outside the table reads "Key 999".
    public var keyName: String { Self.keys[keyCode]?.name ?? "Key \(keyCode)" }

    /// The key alone as VoiceOver should say it, symbols spelled out: "Keypad 1", "Delete", "Left Arrow".
    public var spokenKeyName: String { Self.keys[keyCode]?.spokenName ?? "Key \(keyCode)" }

    // MARK: Key facts

    /// The key's kind, or nil for a key sTools doesn't know.
    public var keyKind: KeyKind? { Self.keys[keyCode]?.kind }

    /// Whether the key is one of F1 to F20.
    public var isFunctionKey: Bool { keyKind == .function }

    /// 1 to 20 for F1 to F20, nil for every other key.
    public var functionKeyNumber: Int? { Self.functionKeyCodes.firstIndex(of: keyCode).map { $0 + 1 } }

    /// Neither ⌘ nor ⌃ is held: the key alone, or with ⇧ and ⌥ only.
    public var lacksCommandAndControl: Bool { modifiers.isDisjoint(with: [.command, .control]) }

    /// A typing or editing key without ⌘ or ⌃: while the hotkey is registered, no other app gets that key.
    public var interferesWithTyping: Bool { keyKind == .typing && lacksCommandAndControl }

    /// Every key code that can carry a hotkey, in ascending order: each virtual key in Karabiner-Elements' table
    /// except the modifier keys, Caps Lock and fn (54–63), Dashboard (130), Launchpad (131) and Mission Control
    /// (160). F21–F24 have no virtual key.
    public static let supportedKeyCodes: [UInt16] = keys.keys.sorted()

    public static func isSupported(keyCode: UInt16) -> Bool { keys[keyCode] != nil }

    // MARK: Validation

    /// The reason this combination cannot be a hotkey, or nil when it can. Modifiers never matter, except in
    /// the exact combinations macOS keeps.
    public var issue: HotkeyComboIssue? {
        guard Self.isSupported(keyCode: keyCode) else { return .unsupportedKey }
        if let reason = Self.reservedReason[self] { return .reserved(reason) }
        return nil
    }

    public var isValid: Bool { issue == nil }

    // MARK: Tables

    private struct Key {
        let name: String
        let spokenName: String
        let kind: KeyKind
    }

    private static let functionKeyCodes: [UInt16] = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]

    /// Name, spoken name and kind for each supported virtual key code. STDesign's `STShortcutKeys` carries the
    /// same names; a test keeps the two in step.
    private static let keys: [UInt16: Key] = {
        var table: [UInt16: Key] = [:]
        func add(_ entries: [(UInt16, String, String)], as kind: KeyKind) {
            for (code, name, spoken) in entries { table[code] = Key(name: name, spokenName: spoken, kind: kind) }
        }
        let letters: [(UInt16, String)] = [
            (0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"), (5, "G"), (4, "H"), (34, "I"),
            (38, "J"), (40, "K"), (37, "L"), (46, "M"), (45, "N"), (31, "O"), (35, "P"), (12, "Q"),
            (15, "R"), (1, "S"), (17, "T"), (32, "U"), (9, "V"), (13, "W"), (7, "X"), (16, "Y"), (6, "Z"),
        ]
        let digits: [(UInt16, String)] = [
            (29, "0"), (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"), (22, "6"), (26, "7"), (28, "8"), (25, "9"),
        ]
        add((letters + digits).map { ($0.0, $0.1, $0.1) }, as: .typing)
        add([
            (27, "-", "Hyphen"), (24, "=", "Equals"), (33, "[", "Left Bracket"), (30, "]", "Right Bracket"),
            (42, "\\", "Backslash"), (41, ";", "Semicolon"), (39, "'", "Quote"), (43, ",", "Comma"),
            (47, ".", "Period"), (44, "/", "Slash"), (50, "`", "Grave Accent"),
            (10, "§", "Section"), (93, "¥", "Yen"), (94, "_", "Underscore"),
        ], as: .typing)
        add([
            (82, "Pad 0", "Keypad 0"), (83, "Pad 1", "Keypad 1"), (84, "Pad 2", "Keypad 2"), (85, "Pad 3", "Keypad 3"),
            (86, "Pad 4", "Keypad 4"), (87, "Pad 5", "Keypad 5"), (88, "Pad 6", "Keypad 6"), (89, "Pad 7", "Keypad 7"),
            (91, "Pad 8", "Keypad 8"), (92, "Pad 9", "Keypad 9"), (65, "Pad .", "Keypad Period"),
            (67, "Pad *", "Keypad Asterisk"), (69, "Pad +", "Keypad Plus"), (75, "Pad /", "Keypad Slash"),
            (78, "Pad -", "Keypad Minus"), (81, "Pad =", "Keypad Equals"), (76, "Pad Enter", "Keypad Enter"),
            (71, "Pad Clear", "Keypad Clear"), (95, "Pad ,", "Keypad Comma"),
        ], as: .typing)
        add([
            (36, "↩", "Return"), (48, "⇥", "Tab"), (49, "Space", "Space"), (51, "⌫", "Delete"), (53, "⎋", "Escape"),
            (117, "⌦", "Forward Delete"), (123, "←", "Left Arrow"), (124, "→", "Right Arrow"),
            (125, "↓", "Down Arrow"), (126, "↑", "Up Arrow"), (115, "↖", "Home"), (119, "↘", "End"),
            (116, "⇞", "Page Up"), (121, "⇟", "Page Down"), (102, "英数", "Eisu"), (104, "かな", "Kana"),
        ], as: .typing)
        add(functionKeyCodes.enumerated().map { ($0.element, "F\($0.offset + 1)", "F\($0.offset + 1)") }, as: .function)
        add([(114, "Help", "Help"), (110, "Menu", "Menu")], as: .other)
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
