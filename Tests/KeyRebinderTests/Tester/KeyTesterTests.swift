import Carbon.HIToolbox
import Testing
@testable import KeyRebinder
import STPlatform

@Suite struct KeyTesterTests {
    let keys = KeyboardLayout(shape: .ansi, formFactor: .laptop).keys.map(\.event) + MouseLayout.buttons.map(\.event)

    private func bindings(_ pairs: [(String, String)], rules: [String] = []) -> [KarabinerEvent: EffectiveBinding] {
        let list = pairs.isEmpty ? nil : "[\(pairs.map { TestConfig.pair($0.0, $0.1) }.joined(separator: ", "))]"
        let config = TestConfig.profile(simple: list, rules: rules.isEmpty ? nil : "[\(rules.joined(separator: ", "))]")
        return EffectiveMapping.bindings(in: config, profile: "P")
    }

    @Test func anUnreboundKeyTracesToItself() {
        let trace = KeyTester.trace(.key("a"), physicalKeys: keys, bindings: [:])
        #expect(trace.sources == [.key("a")])
        #expect(trace.summary() == "A, not rebound.")
    }

    @Test func aRebindTracesBackToThePhysicalKey() {
        let trace = KeyTester.trace(.key("escape"), physicalKeys: keys, bindings: bindings([("caps_lock", "escape"), ("escape", "grave_accent_and_tilde")]))
        #expect(trace.sources == [.key("caps_lock")])
        #expect(trace.summary() == "Esc arrived; it comes from Caps Lock.")
    }

    @Test func severalSourcesAreAllNamed() {
        let trace = KeyTester.trace(.key("left_control"), physicalKeys: keys, bindings: bindings([("caps_lock", "left_control")]))
        #expect(trace.sources == [.key("caps_lock"), .key("left_control")])
        #expect(trace.summary() == "Left Control arrived; it comes from Caps Lock or Left Control.")
    }

    @Test func aKeyNothingProducesSaysSo() {
        let trace = KeyTester.trace(.key("f13"), physicalKeys: keys, bindings: [:])
        #expect(trace.sources.isEmpty)
        #expect(trace.summary().hasPrefix("F13 arrived, but no key on this keyboard produces it"))
    }

    @Test func aComplexRuleOutputIsTraced() {
        let trace = KeyTester.trace(.key("b"), physicalKeys: keys, bindings: bindings([], rules: [TestConfig.rule("R", TestConfig.swap("a", "b"))]))
        #expect(trace.sources == [.key("a"), .key("b")])
    }

    @Test func aliasesMatchTheirKey() {
        let trace = KeyTester.trace(.key("left_option"), physicalKeys: keys, bindings: bindings([("left_alt", "left_command")]))
        #expect(trace.sources.isEmpty)
        let command = KeyTester.trace(.key("left_command"), physicalKeys: keys, bindings: bindings([("left_alt", "left_command")]))
        #expect(command.sources == [.key("left_option"), .key("left_command")])
    }

    @Test func minecraftActionsAreNamed() {
        let keybinds = MinecraftKeybinds.parse(optionsText: "key_key.sprint:key.keyboard.left.control")
        let trace = KeyTester.trace(.key("left_control"), physicalKeys: keys, bindings: [:], minecraftKeybinds: keybinds)
        #expect(trace.minecraftActions == ["Sprint"])
        #expect(trace.summary() == "Left Control, not rebound. In Minecraft: Sprint.")
    }

    @Test func aPressOnAHotkeysKeyNamesIt() {
        let withOption = HotkeyFixtures.hotkey("f18", .option)
        let alone = HotkeyFixtures.hotkey("f18", [], [.toggle(.nbbOverlay), .toggle(.crosshair)])
        let elsewhere = HotkeyFixtures.hotkey("f19")
        let rebound = bindings([("caps_lock", "f18")])
        let trace = KeyTester.trace(.key("f18"), physicalKeys: keys, bindings: rebound, hotkeys: [withOption, elsewhere])
        #expect(trace.hotkeys == [withOption])
        #expect(!trace.hotkeysArePaused)
        #expect(trace.summary() == "F18 arrived; it comes from Caps Lock. sTools hotkey on F18: \u{2325}F18 (Crosshair).")

        let paused = KeyTester.trace(
            .key("f18"), physicalKeys: keys, bindings: rebound, hotkeys: [withOption, alone, elsewhere], hotkeysPaused: true)
        #expect(paused.hotkeys == [withOption, alone])
        #expect(paused.hotkeysArePaused)
        #expect(paused.summary() == "F18 arrived; it comes from Caps Lock. sTools hotkeys on F18: \u{2325}F18 (Crosshair), "
            + "F18 (NBB Overlay + Crosshair). They pause while sTools is in front.")
        let one = KeyTester.trace(.key("f18"), physicalKeys: keys, bindings: rebound, hotkeys: [withOption], hotkeysPaused: true)
        #expect(one.summary().hasSuffix("sTools hotkey on F18: \u{2325}F18 (Crosshair). It pauses while sTools is in front."))
    }

    @Test func theHotkeySentenceComesAfterMinecraftsActionsAndCanBeLeftOut() {
        let keybinds = MinecraftKeybinds.parse(optionsText: "key_key.drop:key.keyboard.q")
        let trace = KeyTester.trace(
            .key("q"), physicalKeys: keys, bindings: [:], minecraftKeybinds: keybinds, hotkeys: [HotkeyFixtures.hotkey("q", .shift)],
            hotkeysPaused: true)
        #expect(trace.summary() == "Q, not rebound. In Minecraft: Drop item. sTools hotkey on Q: \u{21E7}Q (Crosshair). It pauses while sTools is in front.")
        #expect(trace.summary(showsHotkeys: false) == "Q, not rebound. In Minecraft: Drop item.")
    }

    @Test func keysAndButtonsWithoutHotkeysSayNothingMore() {
        let hotkeys = [HotkeyFixtures.hotkey("f18")]
        #expect(KeyTester.trace(.key("a"), physicalKeys: keys, bindings: [:], hotkeys: hotkeys).summary() == "A, not rebound.")
        let button = KeyTester.trace(.pointing("button4"), physicalKeys: keys, bindings: [:], hotkeys: hotkeys, hotkeysPaused: true)
        #expect(button.hotkeys.isEmpty)
        #expect(button.summary() == "Mouse Button 4, not rebound.")
    }

    @Test func arrivingEventsComeFromKeyCodesAndButtons() {
        #expect(KeyTester.event(forVirtualKeyCode: kVK_ANSI_A) == .key("a"))
        #expect(KeyTester.event(forVirtualKeyCode: kVK_Option) == .key("left_option"))
        #expect(KeyTester.event(forButtonNumber: 0) == .pointing("button1"))
        #expect(KeyTester.event(forButtonNumber: 3) == .pointing("button4"))
    }
}
