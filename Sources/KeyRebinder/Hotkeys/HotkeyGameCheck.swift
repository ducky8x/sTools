import STPlatform

/// Which sTools hotkeys take a key Minecraft uses (spec 5.5.4, 6.1). A registered hotkey consumes its key, so while
/// hotkeys are on the game never gets it. Minecraft's uses are its keybinds (`options.txt`, or 1.16.1's defaults
/// when they're unknown) and the combinations 1.16.1 hard-wires. Carbon matches modifiers exactly, so a hotkey also
/// takes a use when the only modifiers it adds are ones Minecraft binds to an action someone holds: ⇧W fires instead
/// of W while you sneak.
///
/// Every text here is plain placeholder wording until M9.
public enum HotkeyGameCheck {
    /// One way Minecraft uses a key.
    public struct Use: Hashable, Sendable {
        /// The key the game reads, under its primary name (`KeyTable.canonical`).
        public let key: KarabinerEvent
        /// Modifiers held with the key in the game's own combination: ⇧ for the pie chart's ⇧F3.
        public let modifiers: HotkeyCombo.Modifiers
        /// What it does, worded to follow "for": "Debug screen", "the pie chart", "F3+C (copies your position for
        /// Ninjabrain Bot)".
        public let description: String
        /// The same for every player and never in `options.txt`: F1, F3, Esc and the hard-wired combinations.
        public let isHardWired: Bool

        public init(key: KarabinerEvent, modifiers: HotkeyCombo.Modifiers = [], description: String, isHardWired: Bool) {
            self.key = key
            self.modifiers = modifiers
            self.description = description
            self.isHardWired = isHardWired
        }
    }

    // MARK: What Minecraft uses

    /// Minecraft 1.16.1's default keybinds as its `options.txt` writes them, for when the real file is unknown.
    static let defaultOptionsText = """
        key_key.attack:key.mouse.left
        key_key.use:key.mouse.right
        key_key.forward:key.keyboard.w
        key_key.left:key.keyboard.a
        key_key.back:key.keyboard.s
        key_key.right:key.keyboard.d
        key_key.jump:key.keyboard.space
        key_key.sneak:key.keyboard.left.shift
        key_key.sprint:key.keyboard.left.control
        key_key.drop:key.keyboard.q
        key_key.inventory:key.keyboard.e
        key_key.chat:key.keyboard.t
        key_key.playerlist:key.keyboard.tab
        key_key.pickItem:key.mouse.middle
        key_key.command:key.keyboard.slash
        key_key.screenshot:key.keyboard.f2
        key_key.togglePerspective:key.keyboard.f5
        key_key.smoothCamera:key.keyboard.unknown
        key_key.fullscreen:key.keyboard.f11
        key_key.spectatorOutlines:key.keyboard.unknown
        key_key.swapOffhand:key.keyboard.f
        key_key.saveToolbarActivator:key.keyboard.c
        key_key.loadToolbarActivator:key.keyboard.x
        key_key.advancements:key.keyboard.l
        key_key.hotbar.1:key.keyboard.1
        key_key.hotbar.2:key.keyboard.2
        key_key.hotbar.3:key.keyboard.3
        key_key.hotbar.4:key.keyboard.4
        key_key.hotbar.5:key.keyboard.5
        key_key.hotbar.6:key.keyboard.6
        key_key.hotbar.7:key.keyboard.7
        key_key.hotbar.8:key.keyboard.8
        key_key.hotbar.9:key.keyboard.9
        """

    /// Minecraft 1.16.1's default keybinds plus the fixed keys (F1, F3, Esc), through the same parser as a real
    /// `options.txt`.
    public static let defaultKeybinds: [MinecraftKeybind] = MinecraftKeybinds.parse(optionsText: defaultOptionsText)

    /// What Minecraft 1.16.1 hard-wires and never writes to `options.txt`: the F3 combinations (a hotkey on the bare
    /// letter, F4 or Esc takes them, since F3 isn't a modifier), the pie chart and frame time graph, and Return and
    /// Pad Enter, which send chat and commands.
    public static let hardWired: [Use] = {
        func withF3(_ code: String, _ name: String, _ what: String) -> Use {
            Use(key: .key(code), description: "F3+\(name) (\(what))", isHardWired: true)
        }
        return [
            withF3("a", "A", "reloads chunks"),
            withF3("b", "B", "shows hitboxes"),
            withF3("c", "C", "copies your position for Ninjabrain Bot"),
            withF3("d", "D", "clears chat"),
            withF3("g", "G", "shows chunk borders"),
            withF3("h", "H", "shows advanced tooltips"),
            withF3("i", "I", "copies block or entity data"),
            withF3("n", "N", "switches to spectator"),
            withF3("p", "P", "pauses when the game loses focus"),
            withF3("q", "Q", "lists the F3 shortcuts"),
            withF3("t", "T", "reloads resource packs"),
            withF3("f4", "F4", "opens the game mode switcher"),
            withF3("escape", "Esc", "pauses without the pause menu"),
            Use(key: .key("f3"), modifiers: .shift, description: "the pie chart", isHardWired: true),
            Use(key: .key("f3"), modifiers: .option, description: "the frame time graph", isHardWired: true),
            Use(key: .key("return_or_enter"), description: "sending chat and commands", isHardWired: true),
            Use(key: .key("keypad_enter"), description: "sending chat and commands", isHardWired: true),
        ]
    }()

    /// Minecraft's actions on each key and button the game receives (under its primary name), from its keybinds,
    /// or from 1.16.1's defaults when they're unknown (nil).
    public static func gameActions(
        minecraftKeybinds: [MinecraftKeybind]?, table: KeyTable = .shared
    ) -> [KarabinerEvent: [String]] {
        var actions: [KarabinerEvent: [String]] = [:]
        for keybind in minecraftKeybinds ?? defaultKeybinds {
            guard let event = keybind.event else { continue }
            actions[table.canonical(event), default: []].append(keybind.display)
        }
        return actions
    }

    /// Every key and button Minecraft binds, under its primary name.
    public static func gameKeys(minecraftKeybinds: [MinecraftKeybind]?, table: KeyTable = .shared) -> Set<KarabinerEvent> {
        Set(gameActions(minecraftKeybinds: minecraftKeybinds, table: table).keys)
    }

    // MARK: Checking a hotkey

    /// What `combo` takes from Minecraft, or nil when it takes nothing. It takes a use (K, M0) of its key K when the
    /// use's modifiers M0 are part of its own and every modifier it adds is one Minecraft binds, on its left or right
    /// key. `minecraftKeybinds` nil checks against 1.16.1's defaults.
    public static func caution(
        for combo: HotkeyCombo, minecraftKeybinds: [MinecraftKeybind]?, table: KeyTable = .shared
    ) -> HotkeyGameCaution? {
        guard let key = table.entry(forVirtualKeyCode: Int(combo.keyCode))?.event else { return nil }
        let byDefault = minecraftKeybinds == nil
        let keybinds = minecraftKeybinds ?? defaultKeybinds
        let bound = boundModifiers(keybinds, table: table)
        let boundFlags = bound.reduce(into: HotkeyCombo.Modifiers()) { $0.formUnion($1.flag) }
        var taken: [HotkeyGameCaution.Taken] = []
        for use in keybindUses(keybinds, table: table) + hardWired {
            guard table.virtualKeyCode(for: use.key) == Int(combo.keyCode), use.modifiers.isSubset(of: combo.modifiers) else { continue }
            let held = combo.modifiers.subtracting(use.modifiers)
            guard held.isSubset(of: boundFlags) else { continue }
            taken.append(HotkeyGameCaution.Taken(use: use, held: held))
        }
        guard !taken.isEmpty else { return nil }
        taken = taken.filter { $0.held.isEmpty } + taken.filter { !$0.held.isEmpty }
        let heldFlags = taken.reduce(into: HotkeyCombo.Modifiers()) { $0.formUnion($1.held) }
        var heldActions: [String] = []
        for modifier in bound where heldFlags.contains(modifier.flag) {
            for action in modifier.actions where !heldActions.contains(action) { heldActions.append(action) }
        }
        return HotkeyGameCaution(
            key: key, taken: taken, heldActions: heldActions,
            usesDefaults: byDefault && taken.contains { !$0.use.isHardWired || !$0.held.isEmpty },
            text: cautionText(combo: combo, taken: taken, bound: bound, byDefault: byDefault))
    }

    /// Names the modifiers Minecraft binds that `combo` lacks: while one of them is held, the hotkey doesn't fire,
    /// because Carbon matches modifiers exactly. "F18 doesn't fire while you hold Shift (Sneak) or Control
    /// (Sprint)." Nil when the combination has every one of them, or Minecraft binds none.
    public static func heldModifierNote(
        for combo: HotkeyCombo, minecraftKeybinds: [MinecraftKeybind]?, table: KeyTable = .shared
    ) -> String? {
        let missing = boundModifiers(minecraftKeybinds ?? defaultKeybinds, table: table).filter { !combo.modifiers.contains($0.flag) }
        guard !missing.isEmpty else { return nil }
        let held = missing.map { "\($0.name) (\($0.actions.joined(separator: ", ")))" }
        var text = "\(combo.displayString) doesn\u{2019}t fire while you hold \(joined(held, last: "or"))"
        if minecraftKeybinds == nil { text += missing.count == 1 ? ", as Minecraft binds it by default" : ", as Minecraft binds them by default" }
        return text + "."
    }

    /// The checker's sentence for `hotkey`, which takes what `caution` says: "The sTools hotkey F3 (Crosshair) keeps
    /// F3 from Minecraft, which uses it for Debug screen."
    static func findingMessage(
        for hotkey: HotkeyBinding, caution: HotkeyGameCaution, minecraftKeybinds: [MinecraftKeybind]?, table: KeyTable = .shared
    ) -> String {
        let combo = hotkey.combo
        let byDefault = minecraftKeybinds == nil
        let actions = HotkeyWording.summary(hotkey.actions)
        let subject = "The sTools hotkey \(combo.displayString)" + (actions.isEmpty ? "" : " (\(actions))")
        let exact = caution.taken.filter { $0.held.isEmpty }.map(\.use)
        if !exact.isEmpty {
            return "\(subject) keeps \(combo.displayString) from Minecraft, which uses it for \(usesList(exact, byDefault: byDefault))."
        }
        let group = heldGroups(caution.taken)[0]
        let name = HotkeyCombo(keyCode: combo.keyCode, modifiers: group.modifiers).displayString
        let held = boundModifiers(minecraftKeybinds ?? defaultKeybinds, table: table).filter { group.held.contains($0.flag) }
        return "\(subject) keeps \(name) from Minecraft while you hold \(held.map(\.name).joined(separator: " and ")): "
            + "Minecraft uses \(name) for \(usesList(group.uses, byDefault: false)) and \(heldPart(held))\(byDefault ? " by default" : "")."
    }

    // MARK: Internals

    /// A modifier Minecraft binds to actions, on its left or right key.
    struct BoundModifier {
        let flag: HotkeyCombo.Modifiers
        let name: String
        let actions: [String]
    }

    /// The order modifiers are named in: Shift and Control first, as Minecraft's Sneak and Sprint.
    private static let modifierKeys: [(flag: HotkeyCombo.Modifiers, name: String, codes: [String])] = [
        (.shift, "Shift", ["left_shift", "right_shift"]),
        (.control, "Control", ["left_control", "right_control"]),
        (.option, "Option", ["left_option", "right_option"]),
        (.command, "Command", ["left_command", "right_command"]),
    ]

    static func boundModifiers(_ keybinds: [MinecraftKeybind], table: KeyTable) -> [BoundModifier] {
        modifierKeys.compactMap { flag, name, codes in
            let keys = Set(codes.map { table.canonical(.key($0)) })
            var actions: [String] = []
            for keybind in keybinds {
                guard let event = keybind.event, keys.contains(table.canonical(event)), !actions.contains(keybind.display) else { continue }
                actions.append(keybind.display)
            }
            return actions.isEmpty ? nil : BoundModifier(flag: flag, name: name, actions: actions)
        }
    }

    /// The keyboard keys Minecraft binds, as uses. F1, F3 and Esc are fixed in every `options.txt`.
    private static func keybindUses(_ keybinds: [MinecraftKeybind], table: KeyTable) -> [Use] {
        let fixed: Set<MinecraftAction> = [.debugScreen, .hideHUD, .pauseMenu]
        return keybinds.compactMap { keybind in
            guard let event = keybind.event, case .key = event else { return nil }
            return Use(key: table.canonical(event), description: keybind.display, isHardWired: fixed.contains(keybind.action))
        }
    }

    /// Uses taken while modifiers are held, grouped by the game's combination and the held modifiers, in order.
    private static func heldGroups(
        _ taken: [HotkeyGameCaution.Taken]
    ) -> [(modifiers: HotkeyCombo.Modifiers, held: HotkeyCombo.Modifiers, uses: [Use])] {
        var groups: [(modifiers: HotkeyCombo.Modifiers, held: HotkeyCombo.Modifiers, uses: [Use])] = []
        for item in taken where !item.held.isEmpty {
            if let index = groups.firstIndex(where: { $0.modifiers == item.use.modifiers && $0.held == item.held }) {
                groups[index].uses.append(item.use)
            } else {
                groups.append((item.use.modifiers, item.held, [item.use]))
            }
        }
        return groups
    }

    private static func cautionText(
        combo: HotkeyCombo, taken: [HotkeyGameCaution.Taken], bound: [BoundModifier], byDefault: Bool
    ) -> String {
        var sentences: [String] = []
        let exact = taken.filter { $0.held.isEmpty }.map(\.use)
        if !exact.isEmpty {
            let name = combo.displayString
            sentences.append("Minecraft uses \(name) for \(usesList(exact, byDefault: byDefault)). While hotkeys are on, it never gets \(name).")
        }
        for group in heldGroups(taken) {
            let name = HotkeyCombo(keyCode: combo.keyCode, modifiers: group.modifiers).displayString
            let held = bound.filter { group.held.contains($0.flag) }
            sentences.append("Minecraft uses \(name) for \(usesList(group.uses, byDefault: false)), and \(heldPart(held))"
                + "\(byDefault ? " by default" : ""): pressing \(name) while holding \(held.map(\.name).joined(separator: " and ")) "
                + "fires this hotkey instead.")
        }
        return sentences.joined(separator: " ")
    }

    /// "Shift for Sneak", "Shift for Sneak and Control for Sprint".
    private static func heldPart(_ held: [BoundModifier]) -> String {
        held.map { "\($0.name) for \(joined($0.actions, last: "and"))" }.joined(separator: " and ")
    }

    /// At most two uses are named, then "and more". With `byDefault`, the last named keybind says so: "Save hotbar
    /// by default and F3+C (...)".
    private static func usesList(_ uses: [Use], byDefault: Bool) -> String {
        let shown = Array(uses.prefix(2))
        var names = shown.map(\.description)
        if byDefault, let last = shown.lastIndex(where: { !$0.isHardWired }) { names[last] += " by default" }
        if uses.count > 2 { return names.joined(separator: ", ") + " and more" }
        return names.joined(separator: " and ")
    }

    /// "A", "A or B", "A, B or C".
    static func joined(_ items: [String], last word: String) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " \(word) " + items[items.count - 1]
    }
}

/// What a hotkey takes from Minecraft, and the caution both hotkey editors show for it.
public struct HotkeyGameCaution: Hashable, Sendable {
    /// One use a hotkey takes.
    public struct Taken: Hashable, Sendable {
        public let use: HotkeyGameCheck.Use
        /// The modifiers the hotkey adds to the game's combination, each one Minecraft binds to a held action. Empty
        /// when the hotkey is exactly the game's combination.
        public let held: HotkeyCombo.Modifiers
    }

    /// The hotkey's key, under its primary name.
    public let key: KarabinerEvent
    /// Every use the hotkey takes: those it matches exactly first, then those it takes while modifiers are held.
    public let taken: [Taken]
    /// Minecraft's actions on the modifiers that must be held for the hotkey to take a use: ["Sneak"] for ⇧W.
    public let heldActions: [String]
    /// Whether what it takes comes from 1.16.1's default keybinds, because Minecraft's own are unknown.
    public let usesDefaults: Bool
    /// The caution: "Minecraft uses F3 for Debug screen. While hotkeys are on, it never gets F3."
    public let text: String

    public var uses: [HotkeyGameCheck.Use] { taken.map(\.use) }
}
