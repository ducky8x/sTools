import Foundation
import Testing
@testable import STPlatform

/// Registers nothing with the system; only records what is registered.
@MainActor
private final class OwnKeyRegistrar: HotkeyRegistering {
    var onPress: (@MainActor (UUID) -> Void)?
    private(set) var active: [UUID: HotkeyCombo] = [:]
    func register(_ combo: HotkeyCombo, id: UUID) throws { active[id] = combo }
    func unregister(id: UUID) { active[id] = nil }
}

private let nbb = HotkeyAction.toggle(.nbbOverlay)
private let backdrop = HotkeyAction.toggle(.windowBackdrop)
private let crosshair = HotkeyAction.toggle(.crosshair)
private let timer = HotkeyAction.startTimer
private let recording = HotkeyAction.startStopRecording

private func combo(_ keyCode: UInt16, _ modifiers: HotkeyCombo.Modifiers = []) -> HotkeyCombo {
    HotkeyCombo(keyCode: keyCode, modifiers: modifiers)
}

private let f6 = combo(97)
private let f7 = combo(98)
private let ctrlOptC = combo(8, [.control, .option])

/// "⌘1 Crosshair", as Home lists a hotkey.
private func listing(_ bindings: [HotkeyBinding]) -> [String] {
    bindings.map { "\($0.combo.displayString) \(HotkeyWording.summary($0.actions))" }
}

/// A center on its own temporary folder, starting from a new install's ⌘1–⌘5 with a hotkey that does two things
/// after them.
@MainActor
private final class OwnKeyHarness {
    let directory = FileManager.default.temporaryDirectory.appending(path: "hotkey-own-\(UUID().uuidString)", directoryHint: .isDirectory)
    let store: SettingsStore
    let registrar = OwnKeyRegistrar()
    let center: HotkeyCenter
    let custom = HotkeyBinding(combo: ctrlOptC, actions: [nbb, crosshair])

    init() {
        store = SettingsStore(directory: directory, debounce: .milliseconds(1))
        store.save(HotkeySettings(isEnabled: true, bindings: HotkeyKeySet.command.bindings() + [custom]))
        center = HotkeyCenter(store: store, registrar: registrar, toolStates: { [:] }, handler: { _ in })
    }

    func own(_ action: HotkeyAction) -> HotkeyBinding? { HotkeyKeySet.ownBinding(for: action, in: center.bindings) }

    isolated deinit { try? FileManager.default.removeItem(at: directory) }
}

/// A tool has one key of its own (spec 6.1): an editor that would add a second hotkey for a tool's action alone asks
/// first, and Replace gives the tool's own hotkey the new key instead.
@MainActor
@Suite("One key of its own per tool")
struct HotkeyOwnKeyTests {
    // MARK: When to ask

    /// A new hotkey for one tool's action alone duplicates the tool's own key, whichever tool: Screen Recording,
    /// Timer Overlay's Start timer and the three overlays alike.
    @Test func aNewHotkeyForAToolsActionAloneWouldReplaceItsOwnKey() {
        let h = OwnKeyHarness()
        for action in HotkeyKeySet.toolActions {
            #expect(h.center.ownHotkeyReplaced(bySaving: [action], editing: nil) == h.own(action), "\(action)")
            #expect(h.center.ownHotkeyReplaced(bySaving: [action, action], editing: nil) == h.own(action), "repeats don't count")
        }
    }

    /// A hotkey that does several things never needs the question, and neither does a tool without a key of its own.
    @Test func severalActionsOrAToolWithoutAKeyNeedNoQuestion() {
        let h = OwnKeyHarness()
        #expect(h.center.ownHotkeyReplaced(bySaving: [crosshair, recording], editing: nil) == nil)
        #expect(h.center.ownHotkeyReplaced(bySaving: [], editing: nil) == nil)
        let crosshairKey = h.own(crosshair)?.id
        h.center.remove(crosshairKey ?? UUID())
        #expect(h.center.ownHotkeyReplaced(bySaving: [crosshair], editing: nil) == nil)
    }

    /// Editing the tool's own key (a new key, the same action) isn't a second key, and neither is editing a second key
    /// an older list kept; editing a hotkey into a tool's action alone is.
    @Test func editingAsksOnlyWhenTheHotkeyBecomesASecondKey() {
        let h = OwnKeyHarness()
        let own = h.own(crosshair)
        #expect(h.center.ownHotkeyReplaced(bySaving: [crosshair], editing: own?.id) == nil)
        #expect(h.center.ownHotkeyReplaced(bySaving: [crosshair], editing: h.custom.id) == own)
        #expect(h.center.ownHotkeyReplaced(bySaving: [backdrop], editing: own?.id) == h.own(backdrop),
                "Crosshair's key turned into a second Window Backdrop key")

        let older = HotkeyBinding(combo: f7, actions: [crosshair])
        h.store.save(HotkeySettings(isEnabled: true, bindings: HotkeyKeySet.command.bindings() + [older]))
        let center = HotkeyCenter(store: h.store, registrar: OwnKeyRegistrar(), toolStates: { [:] }, handler: { _ in })
        #expect(center.ownHotkeyReplaced(bySaving: [crosshair], editing: older.id) == nil, "an older list's second key stays editable")
    }

    // MARK: Replace

    /// Replace gives the tool's own hotkey the new key in one change: it keeps its id and its sidebar place, and no
    /// second key is added.
    @Test func replacingGivesTheOwnKeyTheNewKey() async {
        let h = OwnKeyHarness()
        let own = h.own(crosshair)
        await h.store.flush()
        let writes = h.store.writeCount
        h.center.replaceOwnHotkey(for: crosshair, with: f6, removing: nil)
        #expect(listing(h.center.bindings) == ["F6 Crosshair", "⌘2 Start timer", "⌘3 NBB Overlay", "⌘4 Screen Recording",
                                               "⌘5 Window Backdrop", "⌃⌥C NBB Overlay + Crosshair"])
        #expect(h.own(crosshair)?.id == own?.id)
        #expect(h.registrar.active[own?.id ?? UUID()] == f6)
        #expect(h.center.keySet == nil, "a key set by hand: Custom")
        await h.store.flush()
        #expect(h.store.writeCount == writes + 1, "one change")
    }

    /// Editing a hotkey into a tool's action alone and replacing removes that hotkey: its new key goes to the tool's own.
    @Test func replacingFromAnEditRemovesTheEditedHotkey() {
        let h = OwnKeyHarness()
        let own = h.own(recording)
        h.center.replaceOwnHotkey(for: recording, with: f6, removing: h.custom.id)
        #expect(listing(h.center.bindings) == ["⌘1 Crosshair", "⌘2 Start timer", "⌘3 NBB Overlay", "F6 Screen Recording",
                                               "⌘5 Window Backdrop"])
        #expect(h.own(recording)?.id == own?.id)
        #expect(h.registrar.active[h.custom.id] == nil)
    }

    /// With no key of its own for the tool, the key becomes its own: a new one, or the edited hotkey.
    @Test func withoutAnOwnKeyReplacingSetsOne() {
        let h = OwnKeyHarness()
        h.center.apply(.noKeys)
        h.center.replaceOwnHotkey(for: timer, with: f6, removing: nil)
        #expect(listing(h.center.bindings) == ["F6 Start timer", "⌃⌥C NBB Overlay + Crosshair"])
        h.center.replaceOwnHotkey(for: nbb, with: f7, removing: h.custom.id)
        #expect(listing(h.center.bindings) == ["F6 Start timer", "F7 NBB Overlay"], "in sidebar order")
        #expect(h.own(nbb)?.id == h.custom.id, "the edited hotkey is the tool's own now")
    }

    // MARK: The question

    @Test func theQuestionNamesTheToolAndBothKeys() throws {
        let h = OwnKeyHarness()
        let crosshairKey = try #require(h.own(crosshair))
        #expect(HotkeyWording.replaceOwnKeyQuestion(crosshairKey, with: f6) == "Use F6 for Crosshair?")
        #expect(HotkeyWording.replaceOwnKeyWarning(crosshairKey, with: f6)
            == "Crosshair has one key of its own, ⌘1. This replaces it with F6. Your other hotkeys stay as they are.")
        let timerKey = try #require(h.own(timer))
        #expect(HotkeyWording.replaceOwnKeyQuestion(timerKey, with: f6) == "Use F6 for Timer Overlay?", "the tool, not the action")
        let recordingKey = try #require(h.own(recording))
        #expect(HotkeyWording.replaceOwnKeyWarning(recordingKey, with: f7)
            == "Screen Recording has one key of its own, ⌘4. This replaces it with F7. Your other hotkeys stay as they are.")
        #expect(HotkeyKeySet.toolActions.map(\.toolTitle)
            == ["Crosshair", "Timer Overlay", "NBB Overlay", "Screen Recording", "Window Backdrop"])
    }
}
