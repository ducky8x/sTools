import AppKit
import STDesign
@testable import STPlatform
import SwiftUI
import Testing
import TimerOverlay
@testable import sTools

private let f6 = HotkeyCombo(keyCode: 97, modifiers: [])
private let f7 = HotkeyCombo(keyCode: 98, modifiers: [])
private let f8 = HotkeyCombo(keyCode: 100, modifiers: [])

/// Home ▸ Hotkeys ▸ Key set: one key per tool, in sidebar order, and a new install's ⌘1–⌘5.
@MainActor
@Suite("Key set chooser")
struct HotkeyKeySetChooserTests {
    init() { _ = STFont.register() }

    /// A key set's hotkey does the tool's one action (`ToolID.hotkeyAction`), the one its page's Hotkey row or Timer
    /// Overlay's Key row sets: Start timer for Timer Overlay, the one Screen Recording action for Screen Recording.
    @Test func keySetsGiveTheToolsTheirKeysInSidebarOrder() {
        let tools = ToolID.allCases.filter { $0.hotkeyAction != nil }
        #expect(tools == [.crosshair, .timerOverlay, .nbbOverlay, .screenRecording, .windowBackdrop])
        #expect(HotkeyKeySet.toolActions == tools.compactMap(\.hotkeyAction))
        #expect(ToolID.keyRebinder.hotkeyAction == nil)
        // The digits follow the sidebar's numbers.
        for (tool, combo) in zip(tools, HotkeyKeySet.command.combos) {
            #expect(combo.displayString == "⌘\(tool.number)", "\(tool)")
        }
    }

    @Test func aNewInstallStartsWithCommandOneToFive() throws {
        let harness = Harness(hotkeys: nil)
        let hotkeys = harness.model.hotkeys
        #expect(hotkeys.keySet == .command)
        #expect(hotkeys.bindings.map { "\($0.combo.displayString) \(HotkeyWording.summary($0.actions))" }
            == ["⌘1 Crosshair", "⌘2 Start timer", "⌘3 NBB Overlay", "⌘4 Screen Recording", "⌘5 Window Backdrop"])
        #expect(hotkeys.isEnabled, "on from the first launch, in sTools and Minecraft only")
        #expect(hotkeys.scope == .sToolsAndMinecraft)
        #expect(ToolHotkey.own(for: .toggle(.crosshair), in: hotkeys.bindings)?.combo.displayString == "⌘1")
        #expect(TimerKeyStatus(hotkeys: hotkeys).title == "Start timer: ⌘2")
        // Each page's Hotkey row shows the set's key for its tool, Screen Recording's included.
        for tool in [ToolID.nbbOverlay, .windowBackdrop, .crosshair, .screenRecording] {
            let action = try #require(ToolHotkeyRow(model: harness.model, tool: tool)?.action)
            #expect(ToolHotkey.own(for: action, in: hotkeys.bindings)?.combo.displayString == "⌘\(tool.number)", "\(tool)")
        }

        // They're registered at once (with the harness's fake registrar, never with macOS).
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
        let own = try #require(ToolHotkey.own(for: .toggle(.crosshair), in: harness.model.hotkeys.bindings))
        ToolHotkey.set(f6, for: .toggle(.crosshair), in: harness.model.hotkeys)
        #expect(own.id == ToolHotkey.own(for: .toggle(.crosshair), in: harness.model.hotkeys.bindings)?.id)
        #expect(harness.model.hotkeys.keySet == nil, "a key set by hand on Crosshair's page: Custom")
    }

    /// Every key set is in view on Home at once, in the order the arrow keys cycle through them, and so is each place
    /// hotkeys can work: neither waits behind a menu.
    @Test func everyChoiceIsInViewOnHome() {
        #expect(HotkeysSection.keySetOptions.map(\.title) == ["⌘1–⌘5", "⌃1–⌃5", "⌥1–⌥5", "F13–F17", "None"])
        #expect(HotkeysSection.keySetOptions.map(\.value) == HotkeyKeySet.allCases.map(Optional.some))
        #expect(HotkeysSection.scopeOptions.map(\.title) == ["In sTools and Minecraft", "Everywhere"])
        #expect(HotkeysSection.scopeOptions.map(\.value) == HotkeyScope.allCases)
    }

    /// Under the sets, one line says what the current set gives each tool, in sidebar order, or whose keys they are.
    /// Each key stays on one line with its tool (no-break spaces), so a narrow column wraps only between them.
    @Test func theCaptionSaysWhatTheSetGivesEachTool() {
        func caption(_ set: HotkeyKeySet?) -> String {
            HotkeysSection.keySetCaption(set).replacingOccurrences(of: "\u{00A0}", with: " ")
        }
        #expect(caption(.command)
            == "⌘1 Crosshair · ⌘2 Timer Overlay · ⌘3 NBB Overlay · ⌘4 Screen Recording · ⌘5 Window Backdrop")
        #expect(HotkeysSection.keySetCaption(.command).components(separatedBy: " · ")
            == ["⌘1\u{00A0}Crosshair", "⌘2\u{00A0}Timer\u{00A0}Overlay", "⌘3\u{00A0}NBB\u{00A0}Overlay",
                "⌘4\u{00A0}Screen\u{00A0}Recording", "⌘5\u{00A0}Window\u{00A0}Backdrop"])
        #expect(caption(.control)
            == "⌃1 Crosshair · ⌃2 Timer Overlay · ⌃3 NBB Overlay · ⌃4 Screen Recording · ⌃5 Window Backdrop")
        #expect(caption(.option)
            == "⌥1 Crosshair · ⌥2 Timer Overlay · ⌥3 NBB Overlay · ⌥4 Screen Recording · ⌥5 Window Backdrop")
        #expect(caption(.functionKeys)
            == "F13 Crosshair · F14 Timer Overlay · F15 NBB Overlay · F16 Screen Recording · F17 Window Backdrop")
        #expect(HotkeysSection.keySetCaption(.noKeys) == "No tool has a key of its own.")
        #expect(HotkeysSection.keySetCaption(nil)
            == "Custom: keys you set yourself. Pick a set for one key per tool, in sidebar order.")
    }

    @Test func theQuestionNamesTheKeysSetByHand() {
        var bindings = HotkeyKeySet.command.bindings()
        bindings[0].combo = f6
        #expect(HotkeysSection.keySetQuestion(.control) == "Use ⌃1–⌃5?")
        #expect(HotkeysSection.keySetQuestion(.noKeys) == "Remove every tool's key?")
        #expect(HotkeysSection.keySetWarning(.control, bindings: bindings)
            == "This replaces the key you set for Crosshair (F6). Your other hotkeys stay as they are.")
        bindings[1].combo = f7
        #expect(HotkeysSection.keySetWarning(.noKeys, bindings: bindings)
            == "This removes the keys you set for Crosshair (F6) and Timer Overlay (F7). Your other hotkeys stay as they are.")
        bindings[3].combo = f8
        #expect(HotkeysSection.keySetWarning(.option, bindings: bindings)
            == "This replaces the keys you set for Crosshair (F6), Timer Overlay (F7) and Screen Recording (F8). Your other hotkeys stay as they are.")
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
        #expect(harness.model.hotkeys.bindings.map(\.combo.displayString) == ["F13", "F14", "F15", "F16", "F17"])
        ToolHotkey.set(f6, for: .toggle(.crosshair), in: harness.model.hotkeys)
        #expect(harness.model.hotkeys.keySet == nil)
        let custom = png()
        #expect(Set([command, functionKeys, custom]).count == 3)
    }
}
