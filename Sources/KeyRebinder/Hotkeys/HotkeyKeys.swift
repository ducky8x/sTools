import STPlatform

/// Where sTools hotkeys sit on the drawn keyboard and mouse: which physical keys send a hotkey's key after
/// Karabiner, and which spare key a key could be turned into to carry hotkeys.
public enum HotkeyKeys {
    /// The physical keys and buttons that send the virtual key `keyCode` after Karabiner: keyboard keys in the order
    /// given (keyboard order), then mouse buttons.
    public static func sources(
        ofKeyCode keyCode: UInt16, physicalKeys: [KarabinerEvent], bindings: [KarabinerEvent: EffectiveBinding],
        table: KeyTable = .shared
    ) -> [KarabinerEvent] {
        let matches = physicalKeys.filter { HotkeyTarget.of($0, bindings: bindings, table: table).keyCode == keyCode }
        return matches.filter { !$0.isPointing } + matches.filter(\.isPointing)
    }

    /// Hotkeys placed on physical keys.
    public struct Index: Equatable, Sendable {
        /// Each physical key, under its primary name (`KeyTable.canonical`), with the hotkeys it fires in list order.
        public var byKey: [KarabinerEvent: [HotkeyBinding]] = [:]
        /// Hotkeys no physical key sends, in list order.
        public var unplaced: [HotkeyBinding] = []

        public init(byKey: [KarabinerEvent: [HotkeyBinding]] = [:], unplaced: [HotkeyBinding] = []) {
            self.byKey = byKey
            self.unplaced = unplaced
        }
    }

    /// Places each hotkey on every physical key that sends its key. A hotkey on a key no hotkey can use (a corrupt
    /// entry) is left out: it can never be placed, and Home already flags it.
    public static func index(
        _ hotkeys: [HotkeyBinding], physicalKeys: [KarabinerEvent], bindings: [KarabinerEvent: EffectiveBinding],
        table: KeyTable = .shared
    ) -> Index {
        var keysByCode: [UInt16: [KarabinerEvent]] = [:]
        for key in physicalKeys {
            guard let keyCode = HotkeyTarget.of(key, bindings: bindings, table: table).keyCode else { continue }
            keysByCode[keyCode, default: []].append(table.canonical(key))
        }
        var index = Index()
        for hotkey in hotkeys where HotkeyCombo.isSupported(keyCode: hotkey.combo.keyCode) {
            guard let keys = keysByCode[hotkey.combo.keyCode] else {
                index.unplaced.append(hotkey)
                continue
            }
            for key in keys { index.byKey[key, default: []].append(hotkey) }
        }
        return index
    }

    /// The keys offered as spare keys, best first: F20 down to F13, which few keyboards draw and Minecraft doesn't
    /// bind by default.
    public static let spareCandidates: [KarabinerEvent] = (13...20).reversed().map { .key("f\($0)") }

    /// The first spare candidate that isn't drawn, isn't sent by any physical key, isn't in `gameKeys` (the keys
    /// Minecraft binds) and isn't any hotkey's key. Nil when none is left.
    public static func spareKey(
        physicalKeys: [KarabinerEvent], bindings: [KarabinerEvent: EffectiveBinding], gameKeys: Set<KarabinerEvent>,
        hotkeys: [HotkeyBinding], table: KeyTable = .shared
    ) -> KarabinerEvent? {
        let drawn = Set(physicalKeys.map(table.canonical))
        let sent = Set(physicalKeys.compactMap { EffectiveMapping.output(of: $0, in: bindings, table: table) }.map(table.canonical))
        let game = Set(gameKeys.map(table.canonical))
        let hotkeyCodes = Set(hotkeys.map(\.combo.keyCode))
        return spareCandidates.first { candidate in
            let key = table.canonical(candidate)
            guard let virtualKey = table.virtualKeyCode(for: candidate), let keyCode = UInt16(exactly: virtualKey) else { return false }
            return !drawn.contains(key) && !sent.contains(key) && !game.contains(key) && !hotkeyCodes.contains(keyCode)
        }
    }
}

extension KarabinerEvent {
    /// A mouse button.
    var isPointing: Bool {
        if case .pointing = self { true } else { false }
    }
}
