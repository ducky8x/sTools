import STPlatform

/// What a key or mouse button can do for sTools hotkeys. A hotkey listens for the key macOS receives after
/// Karabiner, so a key carries the hotkeys of what it sends: Caps Lock rebound to F18 carries the F18 hotkeys.
public enum HotkeyTarget: Hashable, Sendable {
    /// It sends `sends`, whose virtual key `keyCode` can be a hotkey's key.
    case key(sends: KarabinerEvent, keyCode: UInt16)
    /// It sends a modifier key, Caps Lock or fn, which macOS can't register alone as a hotkey.
    case modifier(sends: KarabinerEvent)
    /// It sends a mouse button.
    case mouseButton(sends: KarabinerEvent)
    /// Karabiner turns it off (`vk_none`).
    case disabled
    /// A simple rebind makes it send several keys at once (or a key with modifiers).
    case severalKeys
    /// A rule drives it in a way that can't be stated as one key (conditions, tap/hold, several keys...).
    case ruleDriven
    /// It sends something with no virtual key, or one macOS keeps: a media key, Mission Control, F21...
    case unsupported(sends: KarabinerEvent)

    /// The target of the physical `key` under `bindings` (the effective mapping in the current scope). A rebind
    /// written under another name of the key (`left_alt` for Left Option) counts.
    public static func of(
        _ key: KarabinerEvent, bindings: [KarabinerEvent: EffectiveBinding], table: KeyTable = .shared
    ) -> HotkeyTarget {
        if let binding = table.aliases(of: key).lazy.compactMap({ bindings[$0] }).first, !binding.isDrawable {
            switch binding.source {
            case .simple: return .severalKeys
            case .complex: return .ruleDriven
            }
        }
        guard let output = EffectiveMapping.output(of: key, in: bindings, table: table) else { return .ruleDriven }
        return of(output: output, table: table)
    }

    /// The target of a key that sends `output`.
    public static func of(output: KarabinerEvent, table: KeyTable = .shared) -> HotkeyTarget {
        if output == .key("vk_none") { return .disabled }
        if table.isModifier(output) { return .modifier(sends: output) }
        if case .pointing = output { return .mouseButton(sends: output) }
        if let virtualKey = table.virtualKeyCode(for: output), let keyCode = UInt16(exactly: virtualKey),
           HotkeyCombo.isSupported(keyCode: keyCode) {
            return .key(sends: output, keyCode: keyCode)
        }
        return .unsupported(sends: output)
    }

    /// The virtual key a hotkey on this target listens for; nil when it can't carry hotkeys.
    public var keyCode: UInt16? {
        if case .key(_, let keyCode) = self { keyCode } else { nil }
    }
}
