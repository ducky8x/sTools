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
        #expect(HotkeyKeySet.toolActions == [crosshair, timer, nbb, recording, backdrop])
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

    /// VoiceOver says each set's name in words, as it says a hotkey's keys, rather than reading its symbols.
    @Test func eachSetHasASpokenName() {
        #expect(HotkeyKeySet.allCases.map(\.spokenTitle) == [
            "Command 1 to Command 5", "Control 1 to Control 5", "Option 1 to Option 5", "F13 to F17", "None",
        ])
    }

    @Test func eachSetsHotkeysDoTheToolsMainActions() {
        for set in HotkeyKeySet.allCases where set != .noKeys {
            let bindings = set.bindings()
            #expect(bindings.map(\.actions) == [[crosshair], [timer], [nbb], [recording], [backdrop]], "\(set)")
            #expect(bindings.map(\.combo) == set.combos)
            #expect(bindings.allSatisfy { $0.combo.isValid }, "no set holds a combination macOS keeps")
            #expect(HotkeyKeySet.current(in: bindings) == set)
        }
        #expect(HotkeyKeySet.noKeys.bindings().isEmpty)
        // A new install's keys, as the hotkey list names them: Timer Overlay's is Start timer, and Screen Recording's
        // is its one action, the one its page's Hotkey row sets.
        #expect(HotkeyKeySet.command.bindings().map { "\($0.combo.displayString) \(HotkeyWording.summary($0.actions))" }
            == ["⌘1 Crosshair", "⌘2 Start timer", "⌘3 NBB Overlay", "⌘4 Screen Recording", "⌘5 Window Backdrop"])
        #expect(HotkeyKeySet.command.combo(for: .startStopRecording)?.displayString == "⌘4")
        #expect(HotkeyKeySet.functionKeys.combo(for: .startStopRecording)?.displayString == "F16")
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
        #expect(Array(after[0...4]).map(\.actions) == [[crosshair], [timer], [nbb], [recording], [backdrop]])
        #expect(Array(after[0...4]).map(\.id) == Array(before[1...5]).map(\.id), "each own hotkey keeps its id")
        #expect(Array(after[5...]) == [custom, recordingAndTimer], "other hotkeys stay as they are, in their order")
        #expect(HotkeyKeySet.current(in: after) == .functionKeys)
    }

    /// The ⌘1–⌘5 list in an earlier sidebar order (build 449's default: ⌘1 NBB Overlay, ⌘2 Window Backdrop, ⌘3
    /// Crosshair, ⌘4 Start timer, ⌘5 Screen Recording): picking ⌘1–⌘5 gives each tool its sidebar number and lists
    /// them in sidebar order, so Home reads ⌘1 to ⌘5 down the page.
    @Test func pickingASetPutsAListInAnEarlierOrderInSidebarOrder() {
        let earlier = [
            HotkeyBinding(combo: combo(18, .command), actions: [nbb]),
            HotkeyBinding(combo: combo(19, .command), actions: [backdrop]),
            HotkeyBinding(combo: combo(20, .command), actions: [crosshair]),
            HotkeyBinding(combo: combo(21, .command), actions: [timer]),
            HotkeyBinding(combo: combo(23, .command), actions: [recording]),
        ]
        #expect(HotkeyKeySet.current(in: earlier) == nil, "Custom before")
        let after = HotkeyKeySet.command.applied(to: earlier)
        #expect(after.map { "\($0.combo.displayString) \(HotkeyWording.summary($0.actions))" }
            == ["⌘1 Crosshair", "⌘2 Start timer", "⌘3 NBB Overlay", "⌘4 Screen Recording", "⌘5 Window Backdrop"])
        #expect(after.map(\.id) == [earlier[2].id, earlier[3].id, earlier[0].id, earlier[4].id, earlier[1].id])
        #expect(HotkeyKeySet.current(in: after) == .command)
    }

    @Test func aToolWithoutItsOwnHotkeyGetsOneInItsSidebarPlace() {
        let custom = HotkeyBinding(combo: ctrlOptC, actions: [crosshair, nbb])
        let crosshairOnF6 = HotkeyBinding(combo: f6, actions: [crosshair])
        let after = HotkeyKeySet.option.applied(to: [custom, crosshairOnF6])
        #expect(after.map(\.actions) == [[crosshair], [timer], [nbb], [recording], [backdrop], [crosshair, nbb]])
        #expect(after.prefix(5).map(\.combo) == HotkeyKeySet.option.combos)
        #expect(after[0].id == crosshairOnF6.id)
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
        #expect(after[0].id == first.id && after[0].combo == combo(18, .command))
        #expect(after.last == second, "a second hotkey for the tool alone is one of the others")
    }

    /// The order the key sets keep: the tools' own hotkeys first, in sidebar order, then the rest as they were.
    @Test func orderedPutsTheToolsOwnHotkeysFirst() {
        let custom = HotkeyBinding(combo: ctrlOptC, actions: [crosshair, nbb])
        let timerOnF6 = HotkeyBinding(combo: f6, actions: [timer])
        let nbbOnF7 = HotkeyBinding(combo: combo(98), actions: [nbb])
        let secondTimer = HotkeyBinding(combo: combo(100), actions: [timer])
        let ordered = HotkeyKeySet.ordered([custom, timerOnF6, secondTimer, nbbOnF7])
        #expect(ordered == [timerOnF6, nbbOnF7, custom, secondTimer])
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
        let timerKey = center.add(combo: combo(19, .command), actions: [timer])
        let backdropKey = center.add(combo: combo(23, .command), actions: [backdrop])
        await store.flush()
        let writes = store.writeCount

        center.setOwnHotkey(f6, for: nbb)
        await store.flush()
        #expect(store.writeCount == writes + 1, "one change")
        #expect(center.bindings.map(\.actions) == [[timer], [nbb], [backdrop], [crosshair, nbb]])
        #expect(center.bindings.map(\.id).first == timerKey)
        #expect(center.bindings[2].id == backdropKey)
        #expect(center.bindings.last?.id == custom)
        let nbbKey = center.bindings[1].id
        #expect(registrar.active[nbbKey] == f6)

        center.setOwnHotkey(combo(98), for: nbb)
        #expect(center.bindings[1].id == nbbKey)
        #expect(center.bindings[1].combo == combo(98))
        #expect(registrar.active[nbbKey] == combo(98))
        await store.flush()
        let afterChange = store.writeCount
        center.setOwnHotkey(combo(98), for: nbb)
        await store.flush()
        #expect(store.writeCount == afterChange, "the key it already has changes nothing")

        center.setOwnHotkey(nil, for: nbb)
        #expect(center.bindings.map(\.id) == [timerKey, backdropKey, custom])
        #expect(registrar.active[nbbKey] == nil)
        center.setOwnHotkey(nil, for: nbb)
        #expect(center.bindings.map(\.id) == [timerKey, backdropKey, custom])
    }

    /// Clearing a key a tool doesn't have leaves the list as it is, in whatever order it has.
    @MainActor
    @Test func clearingAMissingOwnHotkeyMovesNothing() async {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let custom = HotkeyBinding(combo: ctrlOptC, actions: [crosshair, nbb])
        let nbbKey = HotkeyBinding(combo: combo(18, .command), actions: [nbb])
        store.save(HotkeySettings(isEnabled: true, bindings: [custom, nbbKey]))
        let center = HotkeyCenter(store: store, registrar: KeySetRegistrar(), toolStates: { [:] }, handler: { _ in })
        center.setOwnHotkey(nil, for: crosshair)
        #expect(center.bindings == [custom, nbbKey])
    }

    // MARK: Home's Add Hotkey… and Edit keep the sidebar order

    /// "⌘1 Crosshair", as Home lists a hotkey.
    private func listing(_ bindings: [HotkeyBinding]) -> [String] {
        bindings.map { "\($0.combo.displayString) \(HotkeyWording.summary($0.actions))" }
    }

    /// A hotkey added for one tool's action alone is that tool's own key, so it goes in the tool's sidebar place among
    /// the own keys, as a key set or a tool page puts it; a hotkey that does several things goes at the end.
    @MainActor
    @Test func anAddedToolsOwnHotkeyGoesInItsSidebarPlace() async {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.save(HotkeySettings(isEnabled: true, bindings: [
            HotkeyBinding(combo: combo(18, .command), actions: [crosshair]),
            HotkeyBinding(combo: combo(20, .command), actions: [nbb]),
            HotkeyBinding(combo: ctrlOptC, actions: [crosshair, nbb]),
        ]))
        let registrar = KeySetRegistrar()
        let center = HotkeyCenter(store: store, registrar: registrar, toolStates: { [:] }, handler: { _ in })
        await store.flush()
        let writes = store.writeCount

        let timerKey = center.add(combo: f6, actions: [timer])
        #expect(listing(center.bindings) == ["⌘1 Crosshair", "F6 Start timer", "⌘3 NBB Overlay", "⌃⌥C Crosshair + NBB Overlay"])
        #expect(center.bindings[1].id == timerKey)
        #expect(registrar.active[timerKey] == f6)
        await store.flush()
        #expect(store.writeCount == writes + 1, "one change")

        center.add(combo: combo(98), actions: [recording, timer])
        center.add(combo: combo(23, .command), actions: [backdrop])
        center.add(combo: combo(21, .command), actions: [recording])
        #expect(listing(center.bindings) == ["⌘1 Crosshair", "F6 Start timer", "⌘3 NBB Overlay", "⌘4 Screen Recording",
                                             "⌘5 Window Backdrop", "⌃⌥C Crosshair + NBB Overlay", "F7 Screen Recording + Start timer"])
    }

    /// Editing a hotkey into a tool's action alone moves it to that tool's place, and editing a tool's own key into
    /// several actions moves it after the own keys, ahead of the hotkeys that were after it.
    @MainActor
    @Test func anEditedHotkeyMovesToOrFromItsSidebarPlace() {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let custom = HotkeyBinding(combo: ctrlOptC, actions: [crosshair, nbb])
        let recordingAndTimer = HotkeyBinding(combo: f6, actions: [recording, timer])
        store.save(HotkeySettings(isEnabled: true, bindings: [
            HotkeyBinding(combo: combo(18, .command), actions: [crosshair]),
            HotkeyBinding(combo: combo(20, .command), actions: [nbb]),
            HotkeyBinding(combo: combo(23, .command), actions: [backdrop]),
            custom, recordingAndTimer,
        ]))
        let center = HotkeyCenter(store: store, registrar: KeySetRegistrar(), toolStates: { [:] }, handler: { _ in })

        center.update(recordingAndTimer.id, actions: [timer])
        #expect(listing(center.bindings) == ["⌘1 Crosshair", "F6 Start timer", "⌘3 NBB Overlay", "⌘5 Window Backdrop",
                                             "⌃⌥C Crosshair + NBB Overlay"])
        #expect(center.bindings[1].id == recordingAndTimer.id, "it keeps its id")

        let nbbKey = center.bindings[2].id
        center.update(nbbKey, actions: [nbb, backdrop])
        #expect(listing(center.bindings) == ["⌘1 Crosshair", "F6 Start timer", "⌘5 Window Backdrop",
                                             "⌘3 NBB Overlay + Window Backdrop", "⌃⌥C Crosshair + NBB Overlay"])

        // A new key for a tool's own hotkey keeps its place.
        center.update(center.bindings[0].id, combo: combo(97, .command))
        #expect(listing(center.bindings).first == "⌘F6 Crosshair")
    }

    /// With a tool's own key gone, a second key for that tool alone (an older list can have one) is the tool's own,
    /// and moves up to its place.
    @MainActor
    @Test func removingAToolsOwnHotkeyMovesItsSecondKeyUp() {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = HotkeyBinding(combo: combo(20, .command), actions: [nbb])
        let custom = HotkeyBinding(combo: ctrlOptC, actions: [crosshair, nbb])
        let second = HotkeyBinding(combo: f6, actions: [nbb])
        let crosshairKey = HotkeyBinding(combo: combo(18, .command), actions: [crosshair])
        store.save(HotkeySettings(isEnabled: true, bindings: [crosshairKey, first, custom, second]))
        let center = HotkeyCenter(store: store, registrar: KeySetRegistrar(), toolStates: { [:] }, handler: { _ in })
        center.remove(first.id)
        #expect(center.bindings == [crosshairKey, second, custom])
    }

    // MARK: A new install

    /// A new install's hotkeys are on from the first launch: they work only in sTools and Minecraft by default, so
    /// they take no other app's keys (a browser's ⌘1 still switches tabs).
    @MainActor
    @Test func aNewInstallStartsWithCommandOneToFiveAndHotkeysOn() {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registrar = KeySetRegistrar()
        let center = HotkeyCenter(store: store, registrar: registrar, toolStates: { [:] }, handler: { _ in })
        #expect(center.bindings.map(\.combo) == HotkeyKeySet.command.combos)
        #expect(center.bindings.map(\.actions) == [[crosshair], [timer], [nbb], [recording], [backdrop]])
        #expect(center.keySet == .command)
        #expect(center.isEnabled)
        #expect(center.scope == .sToolsAndMinecraft)
        #expect(Set(registrar.active.values) == Set(HotkeyKeySet.command.combos), "registered at once")
        #expect(center.bindings.allSatisfy { center.status(of: $0.id) == .registered })
    }

    /// Each of a new install's keys does its tool's main action: ⌘2 sends Start timer, and ⌘4 starts or stops a
    /// recording.
    @MainActor
    @Test func aNewInstallsKeysEachDoTheirToolsMainAction() {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registrar = KeySetRegistrar()
        var events: [[HotkeyEvent]] = []
        let center = HotkeyCenter(store: store, registrar: registrar, toolStates: { [:] }, handler: { events.append($0) })
        for binding in center.bindings { registrar.onPress?(binding.id) }
        #expect(events == [[.setTool(.crosshair, isOn: true)], [.startTimer], [.setTool(.nbbOverlay, isOn: true)],
                           [.toggleRecording], [.setTool(.windowBackdrop, isOn: true)]])
    }

    /// A current file keeps what it has: an empty list (the None key set) stays empty. Lists from earlier versions
    /// have tests of their own (`HotkeyMigrationTests`).
    @MainActor
    @Test func anExistingFileKeepsItsList() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"version":2,"value":{"isEnabled":true,"bindings":[]}}"#.utf8).write(to: directory.appending(path: "hotkeys.json"))
        let loaded = store.load(HotkeySettings.self)
        #expect(loaded.bindings.isEmpty)
        #expect(loaded.isEnabled)
        #expect(loaded.scope == .sToolsAndMinecraft)
    }
}
