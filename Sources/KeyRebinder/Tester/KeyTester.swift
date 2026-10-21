import STPlatform

/// The live key tester's logic (spec 5.5.5). Apps see events after Karabiner rebinds them, so the tester takes
/// what arrived and works back, from the current rebinds, to the physical keys that produce it.
public enum KeyTester {
    public struct Trace: Equatable, Sendable {
        /// The event sTools received.
        public let arrived: KarabinerEvent
        /// The physical keys whose effective output is `arrived`, in keyboard order.
        public let sources: [KarabinerEvent]
        /// Minecraft's actions on `arrived`, when its keybinds are known.
        public let minecraftActions: [String]
        /// The sTools hotkeys on `arrived`, whatever their modifiers, in list order.
        public var hotkeys: [HotkeyBinding] = []
        /// Whether hotkeys were paused because sTools was in front, which is why a hotkey's own key could arrive.
        public var hotkeysArePaused = false

        /// The one line the plate shows. `showsHotkeys` false leaves out the sTools hotkeys on the key (the
        /// Prologue's trial).
        public func summary(table: KeyTable = .shared, showsHotkeys: Bool = true) -> String {
            let arrivedName = KeyNames.name(for: arrived, table: table)
            var line: String
            switch sources {
            case []:
                line = "\(arrivedName) arrived, but no key on this keyboard produces it through a simple rebind (a rule with conditions or modifiers may)."
            case [arrived]:
                line = "\(arrivedName), not rebound."
            default:
                let names = sources.map { KeyNames.name(for: $0, table: table) }
                let from = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " or " + names[names.count - 1]
                line = "\(arrivedName) arrived; it comes from \(from)."
            }
            if !minecraftActions.isEmpty { line += " In Minecraft: \(minecraftActions.joined(separator: ", "))." }
            if showsHotkeys, !hotkeys.isEmpty {
                let list = hotkeys.map(\.listing).joined(separator: ", ")
                let one = hotkeys.count == 1
                line += " sTools \(one ? "hotkey" : "hotkeys") on \(arrivedName): \(list)."
                if hotkeysArePaused { line += one ? " It pauses while sTools is in front." : " They pause while sTools is in front." }
            }
            return line
        }
    }

    /// Traces `arrived` back to the physical keys that produce it, and names the sTools `hotkeys` on its key.
    /// `hotkeysPaused` says hotkeys were paused while it arrived.
    public static func trace(
        _ arrived: KarabinerEvent, physicalKeys: [KarabinerEvent], bindings: [KarabinerEvent: EffectiveBinding],
        minecraftKeybinds: [MinecraftKeybind]? = nil, hotkeys: [HotkeyBinding] = [], hotkeysPaused: Bool = false,
        table: KeyTable = .shared
    ) -> Trace {
        let target = table.canonical(arrived)
        let sources = physicalKeys.filter { key in
            EffectiveMapping.output(of: key, in: bindings, table: table).map(table.canonical) == target
        }
        let actions = (minecraftKeybinds ?? []).filter { keybind in
            keybind.event.map(table.canonical) == target
        }.map(\.display)
        let keyCode = table.virtualKeyCode(for: arrived)
        let onKey = keyCode.map { code in hotkeys.filter { Int($0.combo.keyCode) == code } } ?? []
        return Trace(arrived: arrived, sources: sources, minecraftActions: actions, hotkeys: onKey, hotkeysArePaused: hotkeysPaused)
    }

    /// The event a key press arrives as, from its macOS virtual key code.
    public static func event(forVirtualKeyCode keyCode: Int, table: KeyTable = .shared) -> KarabinerEvent? {
        table.entry(forVirtualKeyCode: keyCode)?.event
    }

    /// The event a mouse press arrives as, from `NSEvent.buttonNumber` (0 is the left button).
    public static func event(forButtonNumber number: Int) -> KarabinerEvent {
        .pointing("button\(number + 1)")
    }
}
