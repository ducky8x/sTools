import Foundation
import Testing
@testable import STPlatform

/// Registers nothing with the system; only records what is registered.
@MainActor
private final class KeySetRegistrar: HotkeyRegistering {
    var onPress: (@MainActor (UUID) -> Void)?
    private(set) var active: [UUID: HotkeyCombo] = [:]
    func register(_ combo: HotkeyCombo, id: UUID) throws { active[id] = combo }
    func unregister(id: UUID) { active[id] = nil }
}

private let nbb = HotkeyAction.toggle(.nbbOverlay)
private let backdrop = HotkeyAction.toggle(.windowBackdrop)
private let crosshair = HotkeyAction.toggle(.crosshair)
/// Screen Recording's one action: it has no toggle.
private let recording = HotkeyAction.startStopRecording
private let timer = HotkeyAction.startTimer

private func combo(_ keyCode: UInt16, _ modifiers: HotkeyCombo.Modifiers = []) -> HotkeyCombo {
    HotkeyCombo(keyCode: keyCode, modifiers: modifiers)
}

private let f6 = combo(97)
private let ctrlOptC = combo(8, [.control, .option])

@MainActor
private func temporaryStore() -> (SettingsStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appending(path: "hotkey-sets-\(UUID().uuidString)", directoryHint: .isDirectory)
    return (SettingsStore(directory: directory, debounce: .milliseconds(1)), directory)
}

@Suite("Hotkey key sets")
struct HotkeyKeySetTests {
    // MARK: What each set gives

    @Test func eachSetGivesOneKeyPerToolInSidebarOrder() {
        #expect(HotkeyKeySet.toolActions == [nbb, backdrop, crosshair, timer, recording])
        let digits: [UInt16] = [18, 19, 20, 21, 23]
        #expect(HotkeyKeySet.command.combos == digits.map { combo($0, .command) })
        #expect(HotkeyKeySet.control.combos == digits.map { combo($0, .control) })
        #expect(HotkeyKeySet.option.combos == digits.map { combo($0, .option) })
        #expect(HotkeyKeySet.functionKeys.combos == [105, 107, 113, 106, 64].map { combo($0) })
        #expect(HotkeyKeySet.noKeys.combos.isEmpty)

        #expect(HotkeyKeySet.command.combos.map(\.displayString) == ["⌘1", "⌘2", "⌘3", "⌘4", "⌘5"])
        #expect(HotkeyKeySet.control.combos.map(\.displayString) == ["⌃1", "⌃2", "⌃3", "⌃4", "⌃5"])
        #expect(HotkeyKeySet.option.combos.map(\.displayString) == ["⌥1", "⌥2", "⌥3", "⌥4", "⌥5"])
        #expect(HotkeyKeySet.functionKeys.combos.map(\.displayString) == ["F13", "F14", "F15", "F16", "F17"])
        #expect(HotkeyKeySet.allCases.map(\.title) == ["⌘1–⌘5", "⌃1–⌃5", "⌥1–⌥5", "F13–F17", "None"])
    }

    @Test func eachSetsHotkeysDoTheToolsMainActions() {
        for set in HotkeyKeySet.allCases where set != .noKeys {
            let bindings = set.bindings()
            #expect(bindings.map(\.actions) == [[nbb], [backdrop], [crosshair], [timer], [recording]], "\(set)")
            #expect(bindings.map(\.combo) == set.combos)
            #expect(bindings.allSatisfy { $0.combo.isValid }, "no set holds a combination macOS keeps")
            #expect(HotkeyKeySet.current(in: bindings) == set)
        }
        #expect(HotkeyKeySet.noKeys.bindings().isEmpty)
        // A new install's keys, as the hotkey list names them: Timer Overlay's is Start timer, and Screen Recording's
        // is its one action, the one its page's Hotkey row sets.
        #expect(HotkeyKeySet.command.bindings().map { "\($0.combo.displayString) \(HotkeyWording.summary($0.actions))" }
            == ["⌘1 NBB Overlay", "⌘2 Window Backdrop", "⌘3 Crosshair", "⌘4 Start timer", "⌘5 Screen Recording"])
        #expect(HotkeyKeySet.command.combo(for: .startStopRecording)?.displayString == "⌘5")
        #expect(HotkeyKeySet.functionKeys.combo(for: .startStopRecording)?.displayString == "F17")
    }

    // MARK: Which set the list follows

    @Test func theCurrentSetIsTheOneEveryToolsOwnHotkeyFollows() {
        #expect(HotkeyKeySet.current(in: []) == HotkeyKeySet.noKeys)
        var bindings = HotkeyKeySet.control.bindings()
        bindings.append(HotkeyBinding(combo: ctrlOptC, actions: [crosshair, nbb]))
        #expect(HotkeyKeySet.current(in: bindings) == .control, "other hotkeys don't matter")

        bindings[2].combo = f6
        #expect(HotkeyKeySet.current(in: bindings) == nil, "a key set by hand: Custom")
        bindings[2].combo = combo(20, .control)
        bindings.remove(at: 4)
        #expect(HotkeyKeySet.current(in: bindings) == nil, "a tool without its key: Custom")
    }

    // MARK: Picking a set changes only its own hotkeys

    /// The tools' own hotkeys get the set's keys and come first, in sidebar order, each keeping its id; every other
    /// hotkey stays as it is and follows them, in its order.
    @Test func pickingASetReplacesOnlyTheHotkeysItOwns() {
        let custom = HotkeyBinding(combo: ctrlOptC, actions: [crosshair, nbb])
        let recordingAndTimer = HotkeyBinding(combo: f6, actions: [.startStopRecording, timer])
        let before = [custom] + HotkeyKeySet.command.bindings() + [recordingAndTimer]

        let after = HotkeyKeySet.functionKeys.applied(to: before)
        #expect(after.count == before.count)
        #expect(Array(after[0...4]).map(\.combo) == HotkeyKeySet.functionKeys.combos)
        #expect(Array(after[0...4]).map(\.actions) == [[nbb], [backdrop], [crosshair], [timer], [recording]])
        #expect(Array(after[0...4]).map(\.id) == Array(before[1...5]).map(\.id), "each own hotkey keeps its id")
        #expect(Array(after[5...]) == [custom, recordingAndTimer], "other hotkeys stay as they are, in their order")
        #expect(HotkeyKeySet.current(in: after) == .functionKeys)
    }

    /// The list ducky had before key sets existed, set by hand in the old order: picking ⌘1–⌘5 gives each tool its
    /// sidebar number and lists them in sidebar order, so Home reads ⌘1 to ⌘5 down the page.
    @Test func pickingASetPutsAListInTheOldOrderInSidebarOrder() {
        let old = [
            HotkeyBinding(combo: combo(18, .command), actions: [crosshair]),
            HotkeyBinding(combo: combo(19, .command), actions: [timer]),
            HotkeyBinding(combo: combo(20, .command), actions: [nbb]),
            HotkeyBinding(combo: combo(21, .command), actions: [recording]),
            HotkeyBinding(combo: combo(23, .command), actions: [backdrop]),
        ]
        let after = HotkeyKeySet.command.applied(to: old)
        #expect(after.map { "\($0.combo.displayString) \(HotkeyWording.summary($0.actions))" }
            == ["⌘1 NBB Overlay", "⌘2 Window Backdrop", "⌘3 Crosshair", "⌘4 Start timer", "⌘5 Screen Recording"])
        #expect(after.map(\.id) == [old[2].id, old[4].id, old[0].id, old[1].id, old[3].id])
        #expect(HotkeyKeySet.current(in: after) == .command)
    }

    @Test func aToolWithoutItsOwnHotkeyGetsOneInItsSidebarPlace() {
        let custom = HotkeyBinding(combo: ctrlOptC, actions: [crosshair, nbb])
        let crosshairOnF6 = HotkeyBinding(combo: f6, actions: [crosshair])
        let after = HotkeyKeySet.option.applied(to: [custom, crosshairOnF6])
        #expect(after.map(\.actions) == [[nbb], [backdrop], [crosshair], [timer], [recording], [crosshair, nbb]])
        #expect(after.prefix(5).map(\.combo) == HotkeyKeySet.option.combos)
        #expect(after[2].id == crosshairOnF6.id)
        #expect(after.last == custom)
    }

    @Test func noneRemovesOnlyTheToolsOwnHotkeys() {
        let custom = HotkeyBinding(combo: ctrlOptC, actions: [crosshair, nbb])
        let after = HotkeyKeySet.noKeys.applied(to: HotkeyKeySet.command.bindings() + [custom])
        #expect(after == [custom])
        #expect(HotkeyKeySet.current(in: after) == HotkeyKeySet.noKeys)
    }

    @Test func onlyTheFirstHotkeyWithATheToolsActionAloneIsItsOwn() {
        let first = HotkeyBinding(combo: f6, actions: [crosshair])
        let second = HotkeyBinding(combo: combo(98), actions: [crosshair])
        let after = HotkeyKeySet.command.applied(to: [first, second])
        #expect(after[2].id == first.id && after[2].combo == combo(20, .command))
        #expect(after.last == second, "a second hotkey for the tool alone is one of the others")
    }

    /// The order the key sets keep: the tools' own hotkeys first, in sidebar order, then the rest as they were.
    @Test func orderedPutsTheToolsOwnHotkeysFirst() {
        let custom = HotkeyBinding(combo: ctrlOptC, actions: [crosshair, nbb])
        let timerOnF6 = HotkeyBinding(combo: f6, actions: [timer])
        let nbbOnF7 = HotkeyBinding(combo: combo(98), actions: [nbb])
        let secondTimer = HotkeyBinding(combo: combo(100), actions: [timer])
        let ordered = HotkeyKeySet.ordered([custom, timerOnF6, secondTimer, nbbOnF7])
        #expect(ordered == [nbbOnF7, timerOnF6, custom, secondTimer])
        #expect(HotkeyKeySet.ordered(ordered) == ordered)
        #expect(HotkeyKeySet.ordered([]) == [])
    }

    // MARK: Asking before a key set by hand goes

    @Test func onlyKeysSetByHandCountAsEdits() {
        var bindings = HotkeyKeySet.command.bindings()
        #expect(HotkeyKeySet.control.replacedEdits(in: bindings).isEmpty, "a set's own keys aren't edits")
        #expect(HotkeyKeySet.noKeys.replacedEdits(in: bindings).isEmpty)

        bindings[2].combo = f6
        #expect(HotkeyKeySet.control.replacedEdits(in: bindings).map(\.id) == [bindings[2].id])
        #expect(HotkeyKeySet.noKeys.replacedEdits(in: bindings).map(\.id) == [bindings[2].id])

        bindings[2].combo = combo(20, .option)
        #expect(HotkeyKeySet.control.replacedEdits(in: bindings).isEmpty, "another set's key for that tool isn't one")
        let custom = HotkeyBinding(combo: ctrlOptC, actions: [crosshair, nbb])
        #expect(HotkeyKeySet.control.replacedEdits(in: bindings + [custom]).isEmpty, "custom hotkeys are never replaced")
    }

    // MARK: The center

    @MainActor
    @Test func theCenterPicksASetInOneChange() async {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.save(HotkeySettings(isEnabled: true))
        let registrar = KeySetRegistrar()
        let center = HotkeyCenter(store: store, registrar: registrar, toolStates: { [:] }, handler: { _ in })
        let custom = center.add(combo: ctrlOptC, actions: [crosshair, nbb])
        #expect(center.keySet == HotkeyKeySet.noKeys)

        center.apply(.command)
        #expect(center.keySet == .command)
        #expect(center.bindings.last?.id == custom, "the tools' own hotkeys come first")
        #expect(Set(registrar.active.values) == Set(HotkeyKeySet.command.combos + [ctrlOptC]))
        #expect(center.bindings.allSatisfy { center.status(of: $0.id) == .registered })

        await store.flush()
        let writes = store.writeCount
        center.apply(.command)
        await store.flush()
        #expect(store.writeCount == writes, "picking the set already in use changes nothing")

        center.apply(.noKeys)
        #expect(center.bindings.map(\.id) == [custom])
        #expect(registrar.active.values.sorted { $0.keyCode < $1.keyCode } == [ctrlOptC])
    }

    /// A tool page's Hotkey row sets the tool's own hotkey: a new one lands in its sidebar place among the tools' own
    /// hotkeys, a change keeps its id, and nil removes it, each in one change.
    @MainActor
    @Test func aToolsOwnHotkeyIsSetInItsSidebarPlace() async {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.save(HotkeySettings(isEnabled: true))
        let registrar = KeySetRegistrar()
        let center = HotkeyCenter(store: store, registrar: registrar, toolStates: { [:] }, handler: { _ in })
        let custom = center.add(combo: ctrlOptC, actions: [crosshair, nbb])
        let nbbKey = center.add(combo: combo(18, .command), actions: [nbb])
        let timerKey = center.add(combo: combo(21, .command), actions: [timer])
        await store.flush()
        let writes = store.writeCount

        center.setOwnHotkey(f6, for: crosshair)
        await store.flush()
        #expect(store.writeCount == writes + 1, "one change")
        #expect(center.bindings.map(\.actions) == [[nbb], [crosshair], [timer], [crosshair, nbb]])
        #expect(center.bindings.map(\.id).first == nbbKey)
        #expect(center.bindings[2].id == timerKey)
        #expect(center.bindings.last?.id == custom)
        let crosshairKey = center.bindings[1].id
        #expect(registrar.active[crosshairKey] == f6)

        center.setOwnHotkey(combo(98), for: crosshair)
        #expect(center.bindings[1].id == crosshairKey)
        #expect(center.bindings[1].combo == combo(98))
        #expect(registrar.active[crosshairKey] == combo(98))

        center.setOwnHotkey(nil, for: crosshair)
        #expect(center.bindings.map(\.id) == [nbbKey, timerKey, custom])
        #expect(registrar.active[crosshairKey] == nil)
        center.setOwnHotkey(nil, for: crosshair)
        #expect(center.bindings.map(\.id) == [nbbKey, timerKey, custom])
    }

    // MARK: A new install

    @MainActor
    @Test func aNewInstallStartsWithCommandOneToFiveAndHotkeysOff() {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registrar = KeySetRegistrar()
        let center = HotkeyCenter(store: store, registrar: registrar, toolStates: { [:] }, handler: { _ in })
        #expect(center.bindings.map(\.combo) == HotkeyKeySet.command.combos)
        #expect(center.bindings.map(\.actions) == [[nbb], [backdrop], [crosshair], [timer], [recording]])
        #expect(center.keySet == .command)
        #expect(!center.isEnabled)
        #expect(center.scope == .sToolsAndMinecraft)
        #expect(registrar.active.isEmpty)
    }

    /// Turned on, each of a new install's keys does its tool's main action: ⌘4 sends Start timer, and ⌘5 starts or
    /// stops a recording.
    @MainActor
    @Test func aNewInstallsKeysEachDoTheirToolsMainAction() {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registrar = KeySetRegistrar()
        var events: [[HotkeyEvent]] = []
        let center = HotkeyCenter(store: store, registrar: registrar, toolStates: { [:] }, handler: { events.append($0) })
        center.isEnabled = true
        for binding in center.bindings { registrar.onPress?(binding.id) }
        #expect(events == [[.setTool(.nbbOverlay, isOn: true)], [.setTool(.windowBackdrop, isOn: true)],
                           [.setTool(.crosshair, isOn: true)], [.startTimer], [.toggleRecording]])
    }

    /// Existing files keep what they have: an empty list stays empty.
    @MainActor
    @Test func anExistingFileKeepsItsList() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"version":1,"value":{"isEnabled":true,"bindings":[]}}"#.utf8).write(to: directory.appending(path: "hotkeys.json"))
        let loaded = store.load(HotkeySettings.self)
        #expect(loaded.bindings.isEmpty)
        #expect(loaded.isEnabled)
        #expect(loaded.scope == .sToolsAndMinecraft)
    }
}
