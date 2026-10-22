import STPlatform
import Testing
@testable import sTools

private let f13 = HotkeyCombo(keyCode: 105, modifiers: [])

/// Timer Overlay's Set in Hotkeys… (spec 5.6.2): with a Start-timer key of its own (a key set's ⌘2, or one set by
/// hand), Home ▸ Hotkeys opens that key's editor, ready to record, rather than adding a second key beside it. Without
/// one it opens a new hotkey with Start timer chosen, as before.
@MainActor
@Suite("Set in Hotkeys… with the timer's own key")
struct TimerSetInHotkeysTests {
    @Test func itOpensTheKeyTheTimerAlreadyHas() throws {
        let harness = Harness(hotkeys: nil)
        let own = try #require(ToolHotkey.own(for: .startTimer, in: harness.model.hotkeys.bindings))
        #expect(own.combo.displayString == "⌘2")
        harness.model.navigate(to: .tool(.timerOverlay))
        harness.model.openHotkeysForStartTimer()
        #expect(harness.model.route == .home)
        #expect(harness.model.pendingPageAnchor == .hotkeys)
        #expect(harness.model.pendingEditHotkeyID == own.id)
        #expect(harness.model.pendingNewHotkeyActions == nil)
    }

    /// A hotkey that starts the timer together with other things is Home's to edit, not the timer's own key.
    @Test func aSharedStartTimerHotkeyIsntTheTimersOwn() {
        let harness = Harness()
        harness.model.hotkeys.isEnabled = true
        harness.model.hotkeys.add(combo: f13, actions: [.toggle(.crosshair), .startTimer])
        harness.model.openHotkeysForStartTimer()
        #expect(harness.model.pendingEditHotkeyID == nil)
        #expect(harness.model.pendingNewHotkeyActions == [.startTimer])
    }

    /// While hotkeys are off it asks first, as before; a yes opens the key, a no opens Home ▸ Hotkeys alone.
    @Test func itAsksFirstWhileHotkeysAreOff() throws {
        let harness = Harness(hotkeys: nil)
        harness.model.hotkeys.isEnabled = false
        let own = try #require(ToolHotkey.own(for: .startTimer, in: harness.model.hotkeys.bindings))
        harness.model.confirmTurningOnHotkeys = { false }
        harness.model.openHotkeysForStartTimer()
        #expect(harness.model.pendingEditHotkeyID == nil)
        #expect(harness.model.pendingPageAnchor == .hotkeys)
        harness.model.confirmTurningOnHotkeys = { true }
        harness.model.openHotkeysForStartTimer()
        #expect(harness.model.hotkeys.isEnabled)
        #expect(harness.model.pendingEditHotkeyID == own.id)
    }

    /// Home takes each request once: the editor of the hotkey it names, recording at once, or a new hotkey.
    @Test func homeTakesTheRequestOnce() throws {
        let harness = Harness(hotkeys: nil)
        let own = try #require(ToolHotkey.own(for: .startTimer, in: harness.model.hotkeys.bindings))
        #expect(HotkeysSection.takeEditorRequest(from: harness.model) == nil)

        harness.model.openHotkeysForStartTimer()
        #expect(HotkeysSection.takeEditorRequest(from: harness.model) == .edit(own.id))
        #expect(harness.model.pendingEditHotkeyID == nil)
        #expect(HotkeysSection.takeEditorRequest(from: harness.model) == nil)

        harness.model.hotkeys.setOwnHotkey(nil, for: .startTimer)
        harness.model.openHotkeysForStartTimer()
        #expect(HotkeysSection.takeEditorRequest(from: harness.model) == .add([.startTimer]))
        #expect(harness.model.pendingNewHotkeyActions == nil)
    }
}
