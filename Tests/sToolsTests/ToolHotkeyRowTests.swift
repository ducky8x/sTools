import AppKit
import STDesign
import STPlatform
import SwiftUI
import Testing
@testable import sTools

private let pad1 = HotkeyCombo(keyCode: 83, modifiers: [])
private let f13 = HotkeyCombo(keyCode: 105, modifiers: [])
private let ctrlOptC = HotkeyCombo(keyCode: 8, modifiers: [.control, .option])

/// Each switchable tool's page has a Hotkey row that edits the tool's own hotkey in the one list (spec 6.1).
@MainActor
@Suite("Tool page Hotkey row")
struct ToolHotkeyRowTests {
    @Test func everySwitchableToolHasARowAndTheKeyRebinderHasNone() {
        let harness = Harness(accessibility: .granted)
        #expect(ToolID.nbbOverlay.hotkeyTool == .nbbOverlay)
        #expect(ToolID.windowBackdrop.hotkeyTool == .windowBackdrop)
        #expect(ToolID.crosshair.hotkeyTool == .crosshair)
        #expect(ToolID.screenRecording.hotkeyTool == .screenRecording)
        #expect(ToolID.keyRebinder.hotkeyTool == nil)
        for tool in [ToolID.nbbOverlay, .windowBackdrop, .crosshair, .screenRecording] {
            #expect(ToolHotkeyRow(model: harness.model, tool: tool) != nil)
        }
        #expect(ToolHotkeyRow(model: harness.model, tool: .keyRebinder) == nil)
    }

    /// Setting, changing and clearing the key edit one hotkey in the list Home shows, and it registers like any other.
    @Test func setChangeAndClearEditTheToolsOwnHotkey() throws {
        let harness = Harness(accessibility: .granted)
        let fake = try #require(harness.hotkeyRegistrar as? FakeHotkeyRegistrar)
        let hotkeys = harness.model.hotkeys
        hotkeys.isEnabled = true

        ToolHotkey.set(pad1, for: .crosshair, in: hotkeys)
        let own = try #require(ToolHotkey.own(for: .crosshair, in: hotkeys.bindings))
        #expect(own.combo == pad1)
        #expect(own.actions == [.toggle(.crosshair)])
        #expect(hotkeys.bindings.map(\.id) == [own.id])
        #expect(fake.registered == [own.id: pad1])

        ToolHotkey.set(f13, for: .crosshair, in: hotkeys)
        #expect(hotkeys.bindings.map(\.id) == [own.id])
        #expect(hotkeys.bindings.first?.combo == f13)
        #expect(fake.registered == [own.id: f13])

        // Pressing it toggles the tool, sTools in front or not.
        fake.onPress?(own.id)
        #expect(harness.model.isOn(.crosshair))

        ToolHotkey.set(nil, for: .crosshair, in: hotkeys)
        #expect(hotkeys.bindings.isEmpty)
        #expect(fake.registered.isEmpty)
        ToolHotkey.set(nil, for: .crosshair, in: hotkeys)
        #expect(hotkeys.bindings.isEmpty)
    }

    /// A hotkey that toggles the tool with other things stays as it is: the row names it and adds the tool's own.
    @Test func aSharedHotkeyIsNamedButNotEdited() throws {
        let harness = Harness(accessibility: .granted)
        let hotkeys = harness.model.hotkeys
        let shared = hotkeys.add(combo: ctrlOptC, actions: [.toggle(.crosshair), .toggle(.nbbOverlay)])
        #expect(ToolHotkey.own(for: .crosshair, in: hotkeys.bindings) == nil)
        #expect(ToolHotkey.sharedText(for: .crosshair, in: hotkeys.bindings) == "Also: ⌃⌥C (Crosshair + NBB Overlay).")
        #expect(ToolHotkey.sharedText(for: .windowBackdrop, in: hotkeys.bindings) == nil)

        ToolHotkey.set(pad1, for: .crosshair, in: hotkeys)
        #expect(hotkeys.bindings.count == 2)
        #expect(hotkeys.bindings.first { $0.id == shared }?.combo == ctrlOptC)
        #expect(ToolHotkey.own(for: .crosshair, in: hotkeys.bindings)?.combo == pad1)
    }

    /// The same rules as Home's editor: a key another hotkey has, or one macOS keeps, is refused; its own key isn't.
    @Test func theRowRefusesWhatHomeRefuses() {
        let harness = Harness(accessibility: .granted)
        let hotkeys = harness.model.hotkeys
        hotkeys.add(combo: ctrlOptC, actions: [.toggle(.nbbOverlay)])
        ToolHotkey.set(pad1, for: .crosshair, in: hotkeys)

        let taken = ToolHotkey.refusal(for: ctrlOptC, tool: .crosshair, in: hotkeys)
        #expect(taken == HotkeyWording.conflictText(hotkeys.conflict(for: ctrlOptC)!, combo: ctrlOptC, inList: false))
        #expect(ToolHotkey.refusal(for: HotkeyCombo(keyCode: 12, modifiers: .command), tool: .crosshair, in: hotkeys) != nil)
        #expect(ToolHotkey.refusal(for: pad1, tool: .crosshair, in: hotkeys) == nil)
        #expect(ToolHotkey.refusal(for: f13, tool: .crosshair, in: hotkeys) == nil)
    }

    @Test func theRowRendersItsKeyAndTurnOnWhileOff() throws {
        let harness = Harness(accessibility: .granted)
        let hotkeys = harness.model.hotkeys
        let row = try #require(ToolHotkeyRow(model: harness.model, tool: .crosshair))
        func png() -> Data? { render(row, harness).representation(using: .png, properties: [:]) }
        let empty = png()
        ToolHotkey.set(pad1, for: .crosshair, in: hotkeys)
        let off = png()
        hotkeys.isEnabled = true
        let on = png()
        #expect(Set([empty, off, on]).count == 3)
    }

    private func render(_ row: ToolHotkeyRow, _ harness: Harness) -> NSBitmapImageRep {
        renderBitmap(
            row
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(STColor.background)
                .environment(\.stTheme, harness.model.theme)
                .environment(\.stSoundPlayer, STSoundPlayer.silent),
            size: CGSize(width: 640, height: 200))
    }
}
