import STPlatform
import Testing
@testable import sTools

private let f6 = HotkeyCombo(keyCode: 97, modifiers: [])
private let f7 = HotkeyCombo(keyCode: 98, modifiers: [])
private let ctrlOptC = HotkeyCombo(keyCode: 8, modifiers: [.control, .option])

/// "⌘1 Crosshair", as Home lists a hotkey.
@MainActor
private func listing(_ hotkeys: HotkeyCenter) -> [String] {
    hotkeys.bindings.map { "\($0.combo.displayString) \(HotkeyWording.summary($0.actions))" }
}

/// A new install's ⌘1–⌘5, with a hotkey that does two things after them.
@MainActor
private final class EditorFixture {
    let harness = Harness(hotkeys: nil)
    var hotkeys: HotkeyCenter { harness.model.hotkeys }
    let custom: HotkeyBinding

    init() {
        let id = harness.model.hotkeys.add(combo: ctrlOptC, actions: [.toggle(.nbbOverlay), .toggle(.crosshair)])
        custom = harness.model.hotkeys.bindings.first { $0.id == id }!
    }
}

/// Home ▸ Hotkeys' editor, behind Add Hotkey… and each row's Edit (spec 6.1): what Save and Replace do to the list.
@MainActor
@Suite("Home hotkey editor")
struct HotkeyEditorTests {

    /// Add Hotkey… for a tool's action alone, while the tool has its key: Save changes nothing and asks, and Replace
    /// gives the tool's key the new one, so Home still lists one Crosshair row, in Crosshair's place.
    @Test func addingASecondKeyForAToolAsksAndReplaceKeepsOneRow() throws {
        let fixture = EditorFixture()
        let hotkeys = fixture.hotkeys
        let before = hotkeys.bindings
        let crosshairKey = try #require(ToolHotkey.own(for: .toggle(.crosshair), in: before))
        #expect(HotkeyEditor.save(f6, actions: [.toggle(.crosshair)], existing: nil, in: hotkeys) == .asksToReplace(crosshairKey))
        #expect(hotkeys.bindings == before, "nothing saved before the answer")

        HotkeyEditor.replace(crosshairKey, with: f6, editing: nil, in: hotkeys)
        #expect(listing(hotkeys) == ["F6 Crosshair", "⌘2 Start timer", "⌘3 NBB Overlay", "⌘4 Screen Recording",
                                     "⌘5 Window Backdrop", "⌃⌥C NBB Overlay + Crosshair"])
        #expect(ToolHotkey.own(for: .toggle(.crosshair), in: hotkeys.bindings)?.id == crosshairKey.id)
    }

    /// Screen Recording has one setting: a second key for it alone asks the same way.
    @Test func aSecondScreenRecordingKeyAsksToo() throws {
        let fixture = EditorFixture()
        let hotkeys = fixture.hotkeys
        let recordingKey = try #require(ToolHotkey.own(for: .startStopRecording, in: hotkeys.bindings))
        #expect(HotkeyEditor.save(f6, actions: [.startStopRecording], existing: nil, in: hotkeys) == .asksToReplace(recordingKey))
        HotkeyEditor.replace(recordingKey, with: f6, editing: nil, in: hotkeys)
        #expect(hotkeys.bindings.filter { $0.actions == [.startStopRecording] }.map(\.combo) == [f6])
        #expect(ToolHotkey.sharedText(for: .startStopRecording, in: hotkeys.bindings) == nil)
    }

    /// Editing a hotkey into a tool's action alone asks too, and Replace removes it: its key goes to the tool's own.
    @Test func editingIntoASecondKeyAsksAndReplaceRemovesTheEditedHotkey() throws {
        let fixture = EditorFixture()
        let hotkeys = fixture.hotkeys
        let custom = fixture.custom
        let timerKey = try #require(ToolHotkey.own(for: .startTimer, in: hotkeys.bindings))
        #expect(HotkeyEditor.save(f7, actions: [.startTimer], existing: custom, in: hotkeys) == .asksToReplace(timerKey))
        HotkeyEditor.replace(timerKey, with: f7, editing: custom, in: hotkeys)
        #expect(listing(hotkeys) == ["⌘1 Crosshair", "F7 Start timer", "⌘3 NBB Overlay", "⌘4 Screen Recording", "⌘5 Window Backdrop"])
    }

    /// What needs no question saves at once, in sidebar order: a tool's own key given a new key keeps its place, a
    /// hotkey that does several things goes after the tools' own, and a tool without a key gets one in its place.
    @Test func everythingElseSavesAtOnceInSidebarOrder() throws {
        let fixture = EditorFixture()
        let hotkeys = fixture.hotkeys
        let custom = fixture.custom
        let crosshairKey = try #require(ToolHotkey.own(for: .toggle(.crosshair), in: hotkeys.bindings))
        #expect(HotkeyEditor.save(f6, actions: [.toggle(.crosshair)], existing: crosshairKey, in: hotkeys) == .saved)
        #expect(HotkeyEditor.save(f7, actions: [.startStopRecording, .toggle(.windowBackdrop)], existing: nil, in: hotkeys) == .saved)
        #expect(listing(hotkeys) == ["F6 Crosshair", "⌘2 Start timer", "⌘3 NBB Overlay", "⌘4 Screen Recording",
                                     "⌘5 Window Backdrop", "⌃⌥C NBB Overlay + Crosshair", "F7 Screen Recording + Window Backdrop"])

        hotkeys.remove(try #require(ToolHotkey.own(for: .toggle(.nbbOverlay), in: hotkeys.bindings)).id)
        #expect(HotkeyEditor.save(ctrlOptC, actions: [.toggle(.nbbOverlay)], existing: custom, in: hotkeys) == .saved)
        #expect(listing(hotkeys) == ["F6 Crosshair", "⌘2 Start timer", "⌃⌥C NBB Overlay", "⌘4 Screen Recording",
                                     "⌘5 Window Backdrop", "F7 Screen Recording + Window Backdrop"])
    }
}
