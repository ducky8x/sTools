import Foundation
import Observation
import STPlatform

/// How a key's sTools hotkeys show on it: a gold ring, or a slashed red one when one of them isn't working.
public enum HotkeyMark: Hashable, Sendable {
    /// Every hotkey on the key is registered (live, or paused while sTools listens for keys).
    case working
    /// At least one isn't working: macOS refused it, another hotkey already uses its combination, macOS keeps the
    /// combination, or it has no actions.
    case broken
}

/// sTools hotkeys on the keys (spec 5.5.2, 5.5.3, 6.1). The Key Rebinder shows and edits the app's one hotkey list
/// (`HotkeyCenter`, stored in `hotkeys.json`) one key at a time, and advises Home on it (`HotkeyAdvising`). A hotkey
/// listens for the key macOS receives after Karabiner, so a key carries the hotkeys of what it sends now.
///
/// Nothing here writes `karabiner.json`, runs `karabiner_cli` or waits for Karabiner-Elements, and nothing is gated by
/// `canEdit` or `isBusy`: hotkeys on keys work without Karabiner, where every key sends itself. Every text is plain
/// placeholder wording until M9.
extension KeyRebinderController {
    // MARK: Connecting

    /// Shows `center`'s hotkeys on the keys and makes this controller its advisor. The page follows every change to
    /// the list, its switches and its statuses, one main-actor turn later.
    public func connect(hotkeys center: HotkeyCenter) {
        center.advisor = self
        guard hotkeyCenter !== center else { return }
        hotkeyCenter = center
        follow(center)
        recompute()
    }

    private func follow(_ center: HotkeyCenter) {
        withObservationTracking {
            _ = center.settings
            _ = center.statuses
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.hotkeyCenter === center else { return }
                self.recompute()
                self.follow(center)
            }
        }
    }

    // MARK: Showing hotkeys

    /// Whether the page shows sTools hotkeys at all: a hotkey list is connected and Advanced ▸ Show hotkeys is on.
    public var showsHotkeyLayer: Bool { hotkeyCenter != nil && settings.showsHotkeys }

    /// Home ▸ Hotkeys' master switch.
    public var hotkeysAreOn: Bool { hotkeyCenter?.isEnabled == true }

    /// Switches Home ▸ Hotkeys' master switch on (the key panel's Turn On).
    public func turnHotkeysOn() {
        hotkeyCenter?.isEnabled = true
    }

    /// What Home ▸ Hotkeys has set for every hotkey, for the key panel's Hotkeys part: "Hotkeys work in sTools and
    /// Minecraft · Key set: ⌘1–⌘5", or only in sTools while Accessibility is missing, as Home says. Nil without a
    /// hotkey list.
    public var hotkeyWhereLine: String? {
        let accessibilityGranted = services.permissions.status(.accessibility) == .granted
        return hotkeyCenter.map {
            HotkeyWording.whereAndKeySet(scope: $0.scope, keySet: $0.keySet, accessibilityGranted: accessibilityGranted)
        }
    }

    /// What `key` can do for hotkeys, by what it sends now in the current scope (the preview while a change waits).
    public func hotkeyTarget(for key: KarabinerEvent) -> HotkeyTarget {
        HotkeyTarget.of(key, bindings: derived.bindings)
    }

    /// The hotkeys `key` fires, found under any of its names, in list order, whatever their modifiers. Empty unless
    /// the hotkey layer shows, hotkeys are on and a keyboard is chosen.
    public func hotkeys(on key: KarabinerEvent) -> [HotkeyBinding] {
        derived.hotkeysByKey[KeyTable.shared.canonical(key)] ?? []
    }

    /// The mark `key` wears, or nil when it fires no hotkey.
    public func hotkeyMark(for key: KarabinerEvent) -> HotkeyMark? {
        let hotkeys = hotkeys(on: key)
        guard !hotkeys.isEmpty, let center = hotkeyCenter else { return nil }
        let isBroken = hotkeys.contains { hotkey in
            if case .conflict = center.status(of: hotkey.id) { true } else { false }
        }
        return isBroken ? .broken : .working
    }

    /// What the tooltip and VoiceOver add to `key`: "sTools hotkey F18: Crosshair and NBB Overlay.", or "sTools
    /// hotkeys: F18, Crosshair; Option F18, Screen Recording, not working: Refused by macOS." Nil when it fires no
    /// hotkey.
    public func hotkeyDescription(for key: KarabinerEvent) -> String? {
        let hotkeys = hotkeys(on: key)
        guard !hotkeys.isEmpty, let center = hotkeyCenter else { return nil }
        let isOne = hotkeys.count == 1
        let items = hotkeys.map { hotkey in
            var item = HotkeyWording.spokenName(for: hotkey.combo)
            let actions = HotkeyWording.spokenSummary(hotkey.actions)
            if !actions.isEmpty { item += (isOne ? ": " : ", ") + actions }
            if let problem = HotkeyWording.statusNote(center.status(of: hotkey.id), combo: hotkey.combo, inList: false) {
                item += ", not working: " + (problem.hasSuffix(".") ? String(problem.dropLast()) : problem)
            }
            return item
        }
        return isOne ? "sTools hotkey \(items[0])." : "sTools hotkeys: \(items.joined(separator: "; "))."
    }

    /// Where `key`'s hotkeys listen when that isn't simply the key itself, and which other keys fire them: "Karabiner
    /// turns Caps Lock into F18, so its hotkeys listen for F18. The F18 key fires them too." Adds " while
    /// Karabiner-Elements runs" when it isn't ready, and " on this device" in a device scope. Nil for a key that sends
    /// itself and has no other source, or that can't carry hotkeys.
    public func hotkeySourceNote(for key: KarabinerEvent) -> String? {
        guard case .key(let sends, let keyCode) = hotkeyTarget(for: key) else { return nil }
        let table = KeyTable.shared
        var sentences: [String] = []
        if table.virtualKeyCode(for: key) != Int(keyCode) {
            let output = KeyNames.name(for: sends)
            var sentence = "Karabiner turns \(KeyNames.name(for: key)) into \(output)"
            if settings.scopeDevice != nil { sentence += " on this device" }
            sentence += ", so its hotkeys listen for \(output)"
            if let requirement, requirement != .ready { sentence += " while Karabiner-Elements runs" }
            sentences.append(sentence + ".")
        }
        let others = HotkeyKeys.sources(ofKeyCode: keyCode, physicalKeys: physicalKeys, bindings: derived.bindings)
            .filter { table.canonical($0) != table.canonical(key) }
        if others.count == 1, table.virtualKeyCode(for: others[0]) == Int(keyCode) {
            sentences.append("The \(KeyNames.name(for: others[0])) key fires them too.")
        } else if !others.isEmpty {
            let names = HotkeyGameCheck.joined(others.map { KeyNames.name(for: $0) }, last: "and")
            sentences.append("\(names) \(others.count == 1 ? "fires" : "fire") them too.")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    /// Why `key` can't carry hotkeys, or nil when it can. When Minecraft uses what the key sends now, which holds
    /// Use F20 back, it says so: "macOS can't use Left Shift alone as a hotkey. Minecraft uses it for Sneak."
    public func hotkeyUnavailableText(for key: KarabinerEvent) -> String? {
        let name = KeyNames.name(for: key)
        var text: String
        switch hotkeyTarget(for: key) {
        case .key:
            return nil
        case .modifier(let sends):
            text = "macOS can\u{2019}t use \(KeyNames.name(for: sends)) alone as a hotkey."
        case .mouseButton(let sends):
            text = isLeftOrRightClick(sends) ? "Left and right click can\u{2019}t be hotkeys." : "Mouse buttons can\u{2019}t be hotkeys."
        case .disabled:
            text = "\(name) is turned off in Karabiner-Elements."
        case .severalKeys:
            text = "\(name) sends several keys at once, through a simple rebind."
        case .ruleDriven:
            return "A rule drives \(name), so sTools can\u{2019}t tell which key apps get. Add its hotkey in Home by pressing the key."
        case .unsupported(let sends):
            text = "\(name) sends \(KeyNames.name(for: sends)), which can\u{2019}t be a hotkey."
        }
        if !isLeftOrRightClick(key), let actions = gameActions(onOutputOf: key) {
            text += " Minecraft uses it for \(HotkeyGameCheck.joined(actions, last: "and"))\(minecraftKeybinds == nil ? " by default" : "")."
        }
        return text
    }

    /// The spare key Use F20 puts in Becomes for `key`: F20, else the next of F19…F13 that no drawn key is or sends,
    /// Minecraft doesn't bind and no hotkey uses. Nil when it isn't offered: the key can carry hotkeys already,
    /// Karabiner isn't ready or the file can't be edited, a change waits for Save This or Discard, the key is the left
    /// or right click or driven by a rule, Minecraft uses what the key sends now, or no spare key is left. It only
    /// picks the key; nothing is written until Save.
    public func spareKeyOffer(for key: KarabinerEvent) -> KarabinerEvent? {
        guard canEdit, pendingEdit == nil, !isLeftOrRightClick(key),
              KeyTable.shared.entry(for: key)?.canBeSource != false else { return nil }
        switch hotkeyTarget(for: key) {
        case .key, .ruleDriven: return nil
        case .modifier, .mouseButton, .disabled, .severalKeys, .unsupported: break
        }
        guard gameActions(onOutputOf: key) == nil else { return nil }
        return HotkeyKeys.spareKey(
            physicalKeys: physicalKeys, bindings: derived.bindings,
            gameKeys: HotkeyGameCheck.gameKeys(minecraftKeybinds: minecraftKeybinds), hotkeys: hotkeyCenter?.bindings ?? [])
    }

    /// The line under the plate while hotkeys are off but the list has some, which is why no key wears a ring: "sTools
    /// hotkeys are off, so their keys aren't marked: ⇧⌘U (Crosshair)." Nil while they're on, with none, or without the
    /// hotkey layer.
    public var hotkeysOffText: String? {
        guard showsHotkeyLayer, !hotkeysAreOn, let center = hotkeyCenter, !center.bindings.isEmpty else { return nil }
        return "sTools hotkeys are off, so their keys aren\u{2019}t marked: " + center.bindings.map(\.listing).joined(separator: ", ") + "."
    }

    /// The line under the plate for hotkeys no drawn key or button sends: "Hotkeys no key here sends: F19
    /// (Crosshair), ⌥F20 (NBB Overlay)." Nil when there are none.
    public var unplacedHotkeysText: String? {
        let unplaced = derived.unplacedHotkeys
        guard !unplaced.isEmpty else { return nil }
        return "Hotkeys no key here sends: " + unplaced.map(\.listing).joined(separator: ", ") + "."
    }

    // MARK: Editing

    /// Saves a hotkey on what `key` sends now with `modifiers` held: a new one, or the hotkey `editing`, which keeps
    /// its id. Actions are kept in the pickers' order (`HotkeyAction.allCases`). Returns the hotkey's id, or nil when
    /// nothing was saved: no hotkey list, a key that can't carry hotkeys, no action, a combination that is reserved or
    /// already used by another hotkey, or a second key for a tool's action alone (`ownHotkeyReplaced(bySaving:editing:)`),
    /// which the panel asks about first. With `replacingOwnHotkey`, that tool's own hotkey gets this key instead, as
    /// on Home (spec 6.1), and its id comes back.
    @discardableResult
    public func saveHotkey(
        on key: KarabinerEvent, editing id: UUID?, modifiers: HotkeyCombo.Modifiers, actions: [HotkeyAction],
        replacingOwnHotkey: Bool = false
    ) -> UUID? {
        guard let center = hotkeyCenter, let keyCode = hotkeyTarget(for: key).keyCode, !actions.isEmpty else { return nil }
        let combo = HotkeyCombo(keyCode: keyCode, modifiers: modifiers)
        guard center.conflict(for: combo, excluding: id) == nil else { return nil }
        let ordered = HotkeyAction.allCases.filter(actions.contains)
        let editing = id.flatMap { id in center.bindings.contains { $0.id == id } ? id : nil }
        if let own = center.ownHotkeyReplaced(bySaving: ordered, editing: editing) {
            guard replacingOwnHotkey, let action = own.actions.first else { return nil }
            center.replaceOwnHotkey(for: action, with: combo, removing: editing)
            return own.id
        }
        if let editing {
            center.update(editing, combo: combo, actions: ordered)
            return editing
        }
        return center.add(combo: combo, actions: ordered)
    }

    /// The tool's own hotkey that saving `actions` (on the hotkey `id`, nil for a new one) would duplicate, so the key
    /// panel asks before Replace: a tool has one key of its own (spec 6.1). Nil when saving needs no question, or
    /// without a hotkey list.
    public func ownHotkeyReplaced(bySaving actions: [HotkeyAction], editing id: UUID?) -> HotkeyBinding? {
        hotkeyCenter?.ownHotkeyReplaced(bySaving: actions, editing: id)
    }

    public func deleteHotkey(_ id: UUID) {
        hotkeyCenter?.remove(id)
    }

    // MARK: Becomes

    /// What rebinding `key` to `output` (nil: Remove Rebind) would do to sTools hotkeys, for the captions under
    /// Becomes. Hotkeys never move: "Caps Lock will fire the sTools hotkey F20 (Crosshair)." when the new output
    /// carries hotkeys, and "Its hotkey F18 (Crosshair) stays on F18, and no key will send F18." when no drawn key
    /// would send a hotkey's key any more. The panel shows Remove Rebind's before anything is chosen, right under
    /// what the key sends now, so those say they are about Remove Rebind: "Remove Rebind would make A fire the sTools
    /// hotkey A (Crosshair)." and "Remove Rebind would leave its hotkey F18 (Crosshair) on F18, and no key would send
    /// F18." Worked out on the file in memory; nothing is written.
    public func rebindHotkeyNotes(for key: KarabinerEvent, becoming output: KarabinerEvent?) -> [String] {
        guard showsHotkeyLayer, hotkeysAreOn, layout != nil, let center = hotkeyCenter,
              let root = (pendingEdit?.preview ?? config)?.root, let profile = currentProfile else { return [] }
        let scope = settings.scope
        let from = source(for: key)
        let changed: JSONValue
        do {
            if let output {
                changed = try RebindEditor.setRebind(in: root, profile: profile, from: from, to: output, scope: scope)
            } else {
                changed = try RebindEditor.removeRebind(in: root, profile: profile, from: from, scope: scope)
            }
        } catch {
            return []
        }
        let after = EffectiveMapping.bindings(in: changed, profile: profile, scope: scope)
        let before = hotkeyTarget(for: key).keyCode
        let next = HotkeyTarget.of(key, bindings: after).keyCode
        guard before != next else { return [] }
        let removes = output == nil
        var notes: [String] = []
        if let next {
            let gained = center.bindings.filter { $0.combo.keyCode == next }
            if !gained.isEmpty {
                let list = HotkeyGameCheck.joined(gained.map(\.listing), last: "and")
                let hotkeys = "the sTools \(gained.count == 1 ? "hotkey" : "hotkeys") \(list)"
                notes.append(removes
                    ? "Remove Rebind would make \(KeyNames.name(for: key)) fire \(hotkeys)."
                    : "\(KeyNames.name(for: key)) will fire \(hotkeys).")
            }
        }
        if let before {
            let stranded = center.bindings.filter { $0.combo.keyCode == before }
            if !stranded.isEmpty, HotkeyKeys.sources(ofKeyCode: before, physicalKeys: physicalKeys, bindings: after).isEmpty {
                let name = keyName(forKeyCode: before)
                let list = HotkeyGameCheck.joined(stranded.map(\.listing), last: "and")
                let hotkeys = "\(stranded.count == 1 ? "hotkey" : "hotkeys") \(list)"
                if removes {
                    notes.append("Remove Rebind would leave its \(hotkeys) on \(name), and no key would send \(name).")
                } else {
                    notes.append("Its \(hotkeys) \(stranded.count == 1 ? "stays" : "stay") on \(name), and no key will send \(name).")
                }
            }
        }
        return notes
    }

    // MARK: Helpers

    /// Minecraft's actions on what `key` sends now (its keybinds, or 1.16.1's defaults when they're unknown); nil
    /// when it uses none, or the key sends nothing that can be stated as one key.
    private func gameActions(onOutputOf key: KarabinerEvent) -> [String]? {
        guard let output = EffectiveMapping.output(of: key, in: derived.bindings) else { return nil }
        let actions = HotkeyGameCheck.gameActions(minecraftKeybinds: minecraftKeybinds)[KeyTable.shared.canonical(output)] ?? []
        return actions.isEmpty ? nil : actions
    }

    private func isLeftOrRightClick(_ event: KarabinerEvent) -> Bool {
        (MouseLayout.buttonNumber(of: event) ?? 3) <= 2
    }

    /// "F18", "Keypad 1", "Return": the key with this virtual key code, as the page names keys.
    private func keyName(forKeyCode keyCode: UInt16) -> String {
        KeyTable.shared.entry(forVirtualKeyCode: Int(keyCode)).map { KeyNames.name(for: $0.event) }
            ?? HotkeyCombo(keyCode: keyCode, modifiers: []).keyName
    }
}

// MARK: - Advice for Home

extension KeyRebinderController: HotkeyAdvising {
    /// The Minecraft caution for `combo` and the note naming the held modifiers that keep it from firing, from
    /// Minecraft's keybinds or 1.16.1's defaults. Both hotkey editors show them, through `HotkeyCenter.notes(for:)`.
    public func notes(for combo: HotkeyCombo) -> [HotkeyNote] {
        guard HotkeyCombo.isSupported(keyCode: combo.keyCode) else { return [] }
        var notes: [HotkeyNote] = []
        if let caution = HotkeyGameCheck.caution(for: combo, minecraftKeybinds: minecraftKeybinds) {
            notes.append(HotkeyNote(tone: .caution, text: caution.text))
        }
        if let held = HotkeyGameCheck.heldModifierNote(for: combo, minecraftKeybinds: minecraftKeybinds) {
            notes.append(HotkeyNote(tone: .note, text: held))
        }
        return notes
    }

    /// Which keys on the chosen keyboard send `combo`'s key, for the caption under a Home row: "On Caps Lock", "On
    /// Caps Lock and Mouse Button 4", no text when the key simply sends itself, or "No key on your keyboard sends
    /// F20" (", unless a rule does" when a drawn key is rule-driven). Nil before a keyboard is chosen.
    public func placement(of combo: HotkeyCombo) -> HotkeyPlacement? {
        guard layout != nil, HotkeyCombo.isSupported(keyCode: combo.keyCode) else { return nil }
        let sources = HotkeyKeys.sources(ofKeyCode: combo.keyCode, physicalKeys: physicalKeys, bindings: derived.bindings)
        guard !sources.isEmpty else {
            let ruleDriven = physicalKeys.contains { hotkeyTarget(for: $0) == .ruleDriven }
            let text = "No key on your keyboard sends \(keyName(forKeyCode: combo.keyCode))" + (ruleDriven ? ", unless a rule does" : "")
            return HotkeyPlacement(text: text, canShow: false)
        }
        if sources.count == 1, KeyTable.shared.virtualKeyCode(for: sources[0]) == Int(combo.keyCode) {
            return HotkeyPlacement(text: nil, canShow: true)
        }
        return HotkeyPlacement(text: "On " + HotkeyGameCheck.joined(sources.map { KeyNames.name(for: $0) }, last: "and"), canShow: true)
    }

    /// Selects the first drawn key (or button) that sends `combo`'s key. False when none does or no keyboard is chosen.
    public func selectKey(for combo: HotkeyCombo) -> Bool {
        guard layout != nil,
              let first = HotkeyKeys.sources(ofKeyCode: combo.keyCode, physicalKeys: physicalKeys, bindings: derived.bindings).first
        else { return false }
        selectedKey = first
        return true
    }

    /// Reads `karabiner.json` and Minecraft's keybinds again. Never runs `karabiner_cli`.
    public func prepareAdvice() async {
        await reloadConfig()
        loadMinecraftKeybinds()
        recompute()
    }
}
