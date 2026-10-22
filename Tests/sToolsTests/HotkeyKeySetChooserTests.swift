import AppKit
import STDesign
@testable import STPlatform
import SwiftUI
import Testing
import TimerOverlay
@testable import sTools

private let f6 = HotkeyCombo(keyCode: 97, modifiers: [])
private let f7 = HotkeyCombo(keyCode: 98, modifiers: [])

/// Home ▸ Hotkeys ▸ Key set: one key per tool, in sidebar order, and a new install's ⌘1–⌘5.
@MainActor
@Suite("Key set chooser")
struct HotkeyKeySetChooserTests {
    @Test func keySetsGiveTheToolsTheirKeysInSidebarOrder() {
        let tools = ToolID.allCases.filter { $0.keySetAction != nil }
        #expect(tools == [.nbbOverlay, .windowBackdrop, .crosshair, .timerOverlay, .screenRecording])
        #expect(HotkeyKeySet.toolActions == tools.compactMap(\.keySetAction))
        #expect(ToolID.keyRebinder.keySetAction == nil)
        // The digits follow the sidebar's numbers.
        for (tool, combo) in zip(tools, HotkeyKeySet.command.combos) {
            #expect(combo.displayString == "⌘\(tool.number)", "\(tool)")
        }
    }

    @Test func aNewInstallStartsWithCommandOneToFive() {
        let harness = Harness(hotkeys: nil)
        let hotkeys = harness.model.hotkeys
        #expect(hotkeys.keySet == .command)
        #expect(hotkeys.bindings.map(\.combo.displayString) == ["⌘1", "⌘2", "⌘3", "⌘4", "⌘5"])
        #expect(!hotkeys.isEnabled)
        #expect(hotkeys.scope == .sToolsAndMinecraft)
        #expect(ToolHotkey.own(for: .crosshair, in: hotkeys.bindings)?.combo.displayString == "⌘3")
        #expect(TimerKeyStatus(hotkeys: hotkeys).title == "Start timer: ⌘4")

        // Turned on, they register at once, and each fires its tool's main action.
        hotkeys.isEnabled = true
        let fake = harness.hotkeyRegistrar as! FakeHotkeyRegistrar
        #expect(Set(fake.registered.values) == Set(HotkeyKeySet.command.combos))
    }

    @Test func anExistingListIsKeptAsItIs() {
        let harness = Harness()
        #expect(harness.model.hotkeys.bindings.isEmpty)
        #expect(harness.model.hotkeys.keySet == .noKeys)
    }

    @Test func theChooserNamesTheSetOrCustom() throws {
        #expect(HotkeysSection.keySetTitle(.command) == "⌘1–⌘5")
        #expect(HotkeysSection.keySetTitle(.noKeys) == "None")
        #expect(HotkeysSection.keySetTitle(nil) == "Custom")

        let harness = Harness(hotkeys: nil)
        let own = try #require(ToolHotkey.own(for: .crosshair, in: harness.model.hotkeys.bindings))
        ToolHotkey.set(f6, for: .crosshair, in: harness.model.hotkeys)
        #expect(own.id == ToolHotkey.own(for: .crosshair, in: harness.model.hotkeys.bindings)?.id)
        #expect(harness.model.hotkeys.keySet == nil, "a key set by hand on Crosshair's page: Custom")
    }

    @Test func theQuestionNamesTheKeysSetByHand() {
        var bindings = HotkeyKeySet.command.bindings()
        bindings[2].combo = f6
        #expect(HotkeysSection.keySetQuestion(.control) == "Use ⌃1–⌃5?")
        #expect(HotkeysSection.keySetQuestion(.noKeys) == "Remove every tool's key?")
        #expect(HotkeysSection.keySetWarning(.control, bindings: bindings)
            == "This replaces the key you set for Crosshair (F6). Your other hotkeys stay as they are.")
        bindings[3].combo = f7
        #expect(HotkeysSection.keySetWarning(.noKeys, bindings: bindings)
            == "This removes the keys you set for Crosshair (F6) and Timer Overlay (F7). Your other hotkeys stay as they are.")
    }

    @Test func theChooserRendersItsChoice() {
        let harness = Harness(hotkeys: nil)
        func png() -> Data? {
            renderBitmap(
                VStack(alignment: .leading, spacing: 0) { HotkeysSection(model: harness.model) }
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(STColor.background)
                    .environment(\.stTheme, harness.model.theme)
                    .environment(\.stSoundPlayer, STSoundPlayer.silent),
                size: CGSize(width: 640, height: 640)).representation(using: .png, properties: [:])
        }
        let command = png()
        harness.model.hotkeys.apply(.functionKeys)
        let functionKeys = png()
        #expect(command != functionKeys)
        #expect(harness.model.hotkeys.bindings.map(\.combo.displayString) == ["F13", "F14", "F15", "F16", "F17"])
    }
}
