import STPlatform

/// The conflict & rule checker (spec 5.5.4).
public enum RuleChecker {
    public struct Context: Sendable {
        /// Every key and button the user physically has: the drawn keyboard plus mouse buttons 1–8.
        public var physicalKeys: [KarabinerEvent]
        /// Minecraft's keybinds, when sTools could read `options.txt`. With them, rule findings only concern
        /// keys bound to game actions; without them every key counts as a possible game input.
        public var minecraftKeybinds: [MinecraftKeybind]?
        /// The A.10.x findings; off leaves only the Karabiner conflicts.
        public var includesSpeedrunRules: Bool
        /// The sTools hotkeys macOS accepted, while hotkeys are on (`HotkeyCenter.activeBindings`). A hotkey with no
        /// modifiers consumes its key, so the game never gets it: A.10.1's "several keys produce the same input"
        /// skips that key, as long as Minecraft binds no modifier key (while one is held, the hotkey doesn't fire).
        public var hotkeys: [HotkeyBinding] = []

        public init(
            physicalKeys: [KarabinerEvent], minecraftKeybinds: [MinecraftKeybind]?, includesSpeedrunRules: Bool = true,
            hotkeys: [HotkeyBinding] = []
        ) {
            self.physicalKeys = physicalKeys
            self.minecraftKeybinds = minecraftKeybinds
            self.includesSpeedrunRules = includesSpeedrunRules
            self.hotkeys = hotkeys
        }
    }

    /// Everything wrong with `profile` as it applies in `scope`, Karabiner conflicts first, then rule findings.
    public static func findings(
        in config: JSONValue, profile: String, scope: RebindScope = .allDevices, context: Context, table: KeyTable = .shared
    ) -> [CheckerFinding] {
        guard let profileJSON = ConfigAccess.profile(in: config, named: profile) else { return [] }
        let check = Check(config: config, profileName: profile, profile: profileJSON, scope: scope, context: context, table: table)
        var result = check.duplicateRebinds() + check.shadowedRules() + check.chainedRebinds()
        if context.includesSpeedrunRules {
            result += check.oneKeyOneInput() + check.buttonsOnly() + check.noRepeatAbuse() + check.noMacros()
        }
        return result
    }

    /// "Hotkey takes a game key": one finding for each hotkey that takes a key Minecraft uses (`HotkeyGameCheck`),
    /// pointing at the physical keys that send the hotkey's key, or at the key itself when none does. Needs no
    /// `karabiner.json` (without one every key sends itself). Pass the hotkeys macOS accepted; invalid and
    /// action-less ones are skipped again, and of several on one combination only the first counts. Kept apart from
    /// `findings(in:...)`, so the speedrun-rule switch never hides it.
    public static func hotkeyFindings(
        physicalKeys: [KarabinerEvent], bindings: [KarabinerEvent: EffectiveBinding], hotkeys: [HotkeyBinding],
        minecraftKeybinds: [MinecraftKeybind]?, table: KeyTable = .shared
    ) -> [CheckerFinding] {
        var claimed = Set<HotkeyCombo>()
        var findings: [CheckerFinding] = []
        for hotkey in hotkeys where hotkey.combo.isValid && !hotkey.actions.isEmpty && claimed.insert(hotkey.combo).inserted {
            guard let caution = HotkeyGameCheck.caution(for: hotkey.combo, minecraftKeybinds: minecraftKeybinds, table: table) else {
                continue
            }
            let sources = HotkeyKeys.sources(ofKeyCode: hotkey.combo.keyCode, physicalKeys: physicalKeys, bindings: bindings, table: table)
            findings.append(CheckerFinding(
                kind: .hotkeyTakesGameKey, keys: sources.isEmpty ? [caution.key] : sources,
                message: HotkeyGameCheck.findingMessage(for: hotkey, caution: caution, minecraftKeybinds: minecraftKeybinds, table: table)))
        }
        return findings
    }
}

private struct Check {
    struct SimpleList {
        let isDevice: Bool
        let entries: [EntryList.Entry]
        /// Each entry's raw JSON, in the same order as `entries`.
        let items: [JSONValue]

        var winners: [(entry: EntryList.Entry, item: JSONValue)] {
            zip(entries, items).filter { !$0.0.isOverridden }.map { ($0.0, $0.1) }
        }
    }

    struct Rule {
        let index: Int
        let description: String
        let manipulators: [JSONValue]

        var quotedName: String { description.isEmpty ? "an unnamed rule" : "\u{201C}\(description)\u{201D}" }
    }

    let context: RuleChecker.Context
    let table: KeyTable
    let lists: [SimpleList]
    let rules: [Rule]
    let bindings: [KarabinerEvent: EffectiveBinding]
    /// Canonical event → the Minecraft actions bound to it; `nil` when the keybinds are unknown.
    let gameActions: [KarabinerEvent: [String]]?

    init(config: JSONValue, profileName: String, profile: JSONValue, scope: RebindScope, context: RuleChecker.Context, table: KeyTable) {
        self.context = context
        self.table = table
        var scopes: [RebindScope] = []
        if case .device = scope { scopes.append(scope) }
        scopes.append(.allDevices)
        lists = scopes.compactMap { scope in
            guard let raw = ConfigAccess.list(in: profile, scope: scope, key: RebindEditor.simpleModificationsKey) else { return nil }
            let usable = raw.filter { EntryList.from(of: $0) != nil && $0["to"] != nil }
            let isDevice = if case .device = scope { true } else { false }
            return SimpleList(isDevice: isDevice, entries: EntryList.entries(usable), items: usable)
        }
        rules = (profile["complex_modifications"]?["rules"]?.arrayValue ?? []).enumerated().compactMap { index, rule in
            guard rule["enabled"]?.boolValue != false else { return nil }
            return Rule(index: index, description: rule["description"]?.stringValue ?? "", manipulators: rule["manipulators"]?.arrayValue ?? [])
        }
        bindings = EffectiveMapping.bindings(in: config, profile: profileName, scope: scope)
        gameActions = context.minecraftKeybinds.map { keybinds in
            var actions: [KarabinerEvent: [String]] = [:]
            for keybind in keybinds {
                guard let event = keybind.event else { continue }
                actions[table.canonical(event), default: []].append(keybind.display)
            }
            return actions
        }
    }

    // MARK: Karabiner conflicts

    func duplicateRebinds() -> [CheckerFinding] {
        lists.flatMap { list -> [CheckerFinding] in
            var reported = Set<KarabinerEvent>()
            return list.entries.compactMap { entry in
                guard entry.isOverridden, reported.insert(entry.from).inserted,
                      let winner = list.entries.last(where: { $0.from == entry.from }) else { return nil }
                let place = list.isDevice ? " for this device" : ""
                return CheckerFinding(kind: .duplicateRebind, keys: [entry.from], message:
                    "\(name(entry.from)) is rebound more than once\(place); only the last entry, to \(name(winner.to)), applies.")
            }
        }
    }

    func shadowedRules() -> [CheckerFinding] {
        struct Earlier {
            let event: KarabinerEvent
            let from: JSONValue
            let catchesEveryModifier: Bool
            let rule: Rule
        }
        var earlier: [Earlier] = []
        var findings: [CheckerFinding] = []
        var reported = Set<String>()
        for rule in rules {
            for manipulator in rule.manipulators {
                guard let from = manipulator["from"], let event = Self.singleEvent(in: from) else { continue }
                if let winner = earlier.first(where: { $0.event == event && ($0.catchesEveryModifier || $0.from.semanticallyEquals(from)) }) {
                    guard reported.insert("\(rule.index):\(event)").inserted else { continue }
                    let message = winner.rule.index == rule.index
                        ? "Part of rule \(rule.quotedName) never runs for \(name(event)): an earlier part of the same rule always handles \(name(event)) first."
                        : "Rule \(rule.quotedName) never runs for \(name(event)): rule \(winner.rule.quotedName) above it always handles \(name(event)) first."
                    findings.append(CheckerFinding(kind: .shadowedRule, keys: [event], message: message))
                    continue
                }
                guard manipulator["type"]?.stringValue == "basic", manipulator["conditions"]?.arrayValue?.isEmpty ?? true else { continue }
                let modifiers = from["modifiers"]
                let mandatory = KeyNames.modifierCodes(modifiers?["mandatory"])
                let optional = KeyNames.modifierCodes(modifiers?["optional"])
                earlier.append(Earlier(event: event, from: from, catchesEveryModifier: mandatory.isEmpty && optional.contains("any"), rule: rule))
            }
        }
        return findings
    }

    func chainedRebinds() -> [CheckerFinding] {
        var complexOwner: [KarabinerEvent: Rule] = [:]
        for rule in rules {
            for manipulator in rule.manipulators {
                for event in Self.affectedEvents(manipulator["from"]) where complexOwner[event] == nil {
                    complexOwner[event] = rule
                }
            }
        }
        return lists.flatMap { list in
            list.winners.compactMap { winner -> CheckerFinding? in
                let entry = winner.entry
                guard entry.to.isPlainEvent,
                      let rule = table.aliases(of: entry.to).lazy.compactMap({ complexOwner[$0] }).first else { return nil }
                var message = "\(name(entry.from)) \u{2192} \(name(entry.to)) is changed again by rule \(rule.quotedName)"
                if let binding = bindings[entry.from], case .complex = binding.source, let output = binding.output {
                    message += ", so \(name(entry.from)) ends up as \(name(output))"
                }
                return CheckerFinding(kind: .chainedRebind, keys: [entry.from], message: message + ".")
            }
        }
    }

    // MARK: Speedrun rules

    func oneKeyOneInput() -> [CheckerFinding] {
        var findings: [CheckerFinding] = []

        // A key that causes several inputs at once (A.10.1, A.10.1.a).
        for list in lists {
            for winner in list.winners {
                guard let items = winner.item["to"]?.arrayValue, Self.inputCount(items) > 1,
                      touchesGame(events: Self.outputEvents(items)) else { continue }
                findings.append(CheckerFinding(kind: .oneKeyOneInput, keys: [winner.entry.from], message:
                    "\(name(winner.entry.from)) sends \(names(of: items)) at once; each key may cause only one game input."))
            }
        }
        for rule in rules {
            for manipulator in rule.manipulators {
                let from = Self.affectedEvents(manipulator["from"])
                guard let items = manipulator["to"]?.arrayValue, Self.inputCount(items) > 1,
                      touchesGame(events: Self.outputEvents(items)) else { continue }
                findings.append(CheckerFinding(kind: .oneKeyOneInput, keys: from, message:
                    "Rule \(rule.quotedName) makes \(list(from)) send \(names(of: items)) at once; each key may cause only one game input."))
            }
        }

        // Several keys that end up as the same input. A modifier-free sTools hotkey consumes its key, so the game
        // never gets that input, but only while no modifier is held: macOS matches a hotkey's modifiers exactly, so
        // while one Minecraft binds is held (Shift for Sneak, Control for Sprint) the hotkey doesn't fire and every
        // key reaches the game as that input again. So the skip needs Minecraft to bind no modifier key (its
        // keybinds, or 1.16.1's defaults when they're unknown).
        var producers: [KarabinerEvent: [KarabinerEvent]] = [:]
        var order: [KarabinerEvent] = []
        for key in context.physicalKeys {
            guard let output = output(of: key), output != .key("vk_none") else { continue }
            let canonical = table.canonical(output)
            if producers[canonical] == nil { order.append(canonical) }
            producers[canonical, default: []].append(key)
        }
        let modifiersAreFree = HotkeyGameCheck.boundModifiers(
            context.minecraftKeybinds ?? HotkeyGameCheck.defaultKeybinds, table: table).isEmpty
        let consumed: Set<Int> = modifiersAreFree
            ? Set(context.hotkeys.filter { $0.combo.modifiers.isEmpty && $0.combo.isValid && !$0.actions.isEmpty }.map { Int($0.combo.keyCode) })
            : []
        for output in order {
            guard let keys = producers[output], keys.count > 1, isGameInput(output) else { continue }
            if let virtualKey = table.virtualKeyCode(for: output), consumed.contains(virtualKey) { continue }
            var message = "\(list(keys)) \(keys.count == 2 ? "both" : "all") produce \(name(output))"
            if let actions = gameActions?[output] { message += " (\(actions.joined(separator: ", ")) in Minecraft)" }
            findings.append(CheckerFinding(kind: .oneKeyOneInput, keys: keys, message: message + "; each game input may have only one key."))
        }
        return findings
    }

    func buttonsOnly() -> [CheckerFinding] {
        var findings: [CheckerFinding] = []
        for list in lists {
            for winner in list.winners where Self.scrolls(winner.item["to"]?.arrayValue ?? []) {
                findings.append(CheckerFinding(kind: .buttonsOnly, keys: [winner.entry.from], message:
                    "\(name(winner.entry.from)) is rebound to the scroll wheel; rebinds must be to buttons."))
            }
        }
        for rule in rules {
            for manipulator in rule.manipulators where Self.scrolls(Self.allOutputs(manipulator)) {
                let from = Self.affectedEvents(manipulator["from"])
                findings.append(CheckerFinding(kind: .buttonsOnly, keys: from, message:
                    "Rule \(rule.quotedName) turns \(list(from)) into scrolling; rebinds must be to buttons."))
            }
        }
        return findings
    }

    func noRepeatAbuse() -> [CheckerFinding] {
        let functions: [(action: MinecraftAction, display: String, fallback: KarabinerEvent)] = [
            (.attack, "Attack/Destroy", .pointing("button1")),
            (.use, "Use Item/Place Block", .pointing("button2")),
        ]
        var findings: [CheckerFinding] = []
        for function in functions {
            let bound: KarabinerEvent?
            if let keybinds = context.minecraftKeybinds {
                bound = keybinds.first { $0.action == function.action }?.event
            } else {
                bound = function.fallback
            }
            guard let bound else { continue }
            if case .key = bound {
                findings.append(CheckerFinding(kind: .noRepeatAbuse, keys: [bound], message:
                    "Minecraft\u{2019}s \(function.display) is bound to \(name(bound)), a keyboard key."))
                continue
            }
            let target = table.canonical(bound)
            for key in context.physicalKeys {
                guard case .key = key, let output = output(of: key), table.canonical(output) == target else { continue }
                findings.append(CheckerFinding(kind: .noRepeatAbuse, keys: [key], message:
                    "\(name(key)) sends \(name(bound)), which Minecraft uses for \(function.display)."))
            }
        }
        return findings
    }

    func noMacros() -> [CheckerFinding] {
        var findings: [CheckerFinding] = []
        for rule in rules {
            for manipulator in rule.manipulators {
                var features: [String] = []
                let delayed = manipulator["to_delayed_action"]
                if Self.hasEvents(delayed?["to_if_invoked"]) || Self.hasEvents(delayed?["to_if_canceled"]) { features.append("sends delayed actions") }
                if Self.hasEvents(manipulator["to_if_alone"]) { features.append("sends extra keys when tapped") }
                if Self.hasEvents(manipulator["to_if_held_down"]) { features.append("sends extra keys when held") }
                if Self.hasEvents(manipulator["to_after_key_up"]) { features.append("sends extra keys after release") }
                if Self.repeatsAnInput(manipulator["to"]?.arrayValue ?? []) { features.append("repeats an input") }
                guard !features.isEmpty else { continue }
                let from = Self.affectedEvents(manipulator["from"])
                guard touchesGame(events: from + Self.outputEvents(Self.allOutputs(manipulator))) else { continue }
                let on = from.isEmpty ? "" : " on \(list(from))"
                findings.append(CheckerFinding(kind: .noMacros, keys: from, message:
                    "Rule \(rule.quotedName) \(features.joined(separator: " and "))\(on)."))
            }
        }
        return findings
    }

    // MARK: Effective output

    private func output(of key: KarabinerEvent) -> KarabinerEvent? {
        EffectiveMapping.output(of: key, in: bindings, table: table)
    }

    private func isGameInput(_ event: KarabinerEvent) -> Bool {
        guard let gameActions else { return true }
        return gameActions[table.canonical(event)] != nil
    }

    private func touchesGame(events: [KarabinerEvent]) -> Bool {
        gameActions == nil || events.contains(where: isGameInput)
    }

    // MARK: Naming

    private func name(_ event: KarabinerEvent) -> String { KeyNames.name(for: event, table: table) }

    private func list(_ events: [KarabinerEvent]) -> String {
        events.isEmpty ? "a key" : events.map(name).joinedAsList()
    }

    private func names(of items: [JSONValue]) -> String {
        items.map { KeyNames.name(forEventObject: $0, table: table) }.joinedAsList()
    }

    // MARK: JSON helpers

    /// The one event of a `from` without `simultaneous` or `any`.
    static func singleEvent(in from: JSONValue) -> KarabinerEvent? {
        guard let members = from.members, from["simultaneous"] == nil else { return nil }
        let eventMembers = members.filter { KarabinerEvent.plainEventKeys.contains($0.key) }
        return eventMembers.count == 1 ? KarabinerEvent(json: .object(eventMembers)) : nil
    }

    /// The keys a `from` reacts to: its one event, or each key of `simultaneous`.
    static func affectedEvents(_ from: JSONValue?) -> [KarabinerEvent] {
        guard let from else { return [] }
        if let simultaneous = from["simultaneous"]?.arrayValue { return simultaneous.compactMap(singleEvent(in:)) }
        return singleEvent(in: from).map { [$0] } ?? []
    }

    /// How many inputs a `to` list presses: each event plus each modifier attached to it.
    static func inputCount(_ items: [JSONValue]) -> Int {
        items.reduce(0) { count, item in
            guard singleEvent(in: item) != nil else { return count }
            return count + 1 + KeyNames.modifierCodes(item["modifiers"]).count
        }
    }

    /// Every key a `to` list presses, modifiers included.
    static func outputEvents(_ items: [JSONValue]) -> [KarabinerEvent] {
        items.flatMap { item -> [KarabinerEvent] in
            guard let event = singleEvent(in: item) else { return [] }
            return KeyNames.modifierCodes(item["modifiers"]).map(KarabinerEvent.key) + [event]
        }
    }

    /// Every event list a manipulator can send.
    static func allOutputs(_ manipulator: JSONValue) -> [JSONValue] {
        let delayed = manipulator["to_delayed_action"]
        return [manipulator["to"], manipulator["to_if_alone"], manipulator["to_if_held_down"], manipulator["to_after_key_up"],
                delayed?["to_if_invoked"], delayed?["to_if_canceled"]]
            .flatMap { $0?.arrayValue ?? [] }
    }

    static func hasEvents(_ list: JSONValue?) -> Bool {
        (list?.arrayValue ?? []).contains { singleEvent(in: $0) != nil }
    }

    static func scrolls(_ items: [JSONValue]) -> Bool {
        items.contains { item in
            guard let mouseKey = item["mouse_key"] else { return false }
            return ["vertical_wheel", "horizontal_wheel"].contains { (mouseKey[$0]?.numberValue?.doubleValue ?? 0) != 0 }
        }
    }

    static func repeatsAnInput(_ items: [JSONValue]) -> Bool {
        let events = items.compactMap(singleEvent(in:))
        return Set(events).count < events.count
    }
}

private extension Array where Element == String {
    func joinedAsList() -> String {
        switch count {
        case 0: ""
        case 1: self[0]
        case 2: "\(self[0]) and \(self[1])"
        default: dropLast().joined(separator: ", ") + ", and " + self[count - 1]
        }
    }
}
