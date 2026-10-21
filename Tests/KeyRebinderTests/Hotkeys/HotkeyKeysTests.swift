import Testing
@testable import KeyRebinder
import STPlatform

@Suite struct HotkeyKeysTests {
    @Test func sourcesKeepKeyboardOrderWithMouseButtonsLast() {
        let bindings = HotkeyFixtures.bindings(
            [("caps_lock", "f18"), ("q", "f18")], simple: [HotkeyFixtures.buttonPair("button4", "f18")])
        // Even when the buttons come first in the list they are given in.
        let keys = MouseLayout.buttons.map(\.event) + KeyboardLayout(shape: .ansi, formFactor: .laptop).keys.map(\.event)
        let sources = HotkeyKeys.sources(ofKeyCode: 79, physicalKeys: keys, bindings: bindings)
        #expect(sources == [.key("q"), .key("caps_lock"), .pointing("button4")])
    }

    @Test func aKeyThatSendsItselfIsItsOwnSource() {
        #expect(HotkeyKeys.sources(ofKeyCode: 83, physicalKeys: HotkeyFixtures.fullSize, bindings: [:]) == [.key("keypad_1")])
        #expect(HotkeyKeys.sources(ofKeyCode: 83, physicalKeys: HotkeyFixtures.laptop, bindings: [:]).isEmpty)
    }

    @Test func anF18HotkeySitsOnCapsLockOnALaptopAndOnCapsLockAndF18OnAFullSizeKeyboard() {
        let bindings = HotkeyFixtures.bindings([("caps_lock", "f18")])
        let hotkey = HotkeyFixtures.hotkey("f18")
        let laptop = HotkeyKeys.index([hotkey], physicalKeys: HotkeyFixtures.laptop, bindings: bindings)
        #expect(laptop.byKey == [.key("caps_lock"): [hotkey]])
        #expect(laptop.unplaced.isEmpty)
        let fullSize = HotkeyKeys.index([hotkey], physicalKeys: HotkeyFixtures.fullSize, bindings: bindings)
        #expect(fullSize.byKey == [.key("caps_lock"): [hotkey], .key("f18"): [hotkey]])
    }

    @Test func hotkeysOnOneKeyKeepListOrderAndOneSentByTwoKeysSitsOnBoth() {
        let bindings = HotkeyFixtures.bindings([("caps_lock", "f18"), ("right_option", "f18")])
        let withOption = HotkeyFixtures.hotkey("f18", .option, [.toggle(.nbbOverlay)])
        let alone = HotkeyFixtures.hotkey("f18")
        let index = HotkeyKeys.index([withOption, alone], physicalKeys: HotkeyFixtures.laptop, bindings: bindings)
        #expect(index.byKey[.key("caps_lock")] == [withOption, alone])
        #expect(index.byKey[.key("right_option")] == [withOption, alone])
    }

    @Test func f20OnALaptopWithoutARebindIsUnplaced() {
        let hotkey = HotkeyFixtures.hotkey("f20")
        let index = HotkeyKeys.index([hotkey], physicalKeys: HotkeyFixtures.laptop, bindings: [:])
        #expect(index.byKey.isEmpty)
        #expect(index.unplaced == [hotkey])
    }

    @Test func keysAreIndexedUnderTheirPrimaryName() {
        let jis = HotkeyFixtures.physicalKeys(.jis, .laptop)
        let hotkey = HotkeyFixtures.hotkey("japanese_eisuu")
        let index = HotkeyKeys.index([hotkey], physicalKeys: jis, bindings: [:])
        #expect(index.byKey == [KeyTable.shared.canonical(.key("japanese_eisuu")): [hotkey]])
    }

    @Test func aHotkeyOnAKeyNoHotkeyCanUseIsLeftOut() {
        let invalid = HotkeyBinding(combo: HotkeyCombo(keyCode: 56, modifiers: []), actions: [.toggle(.crosshair)])
        let index = HotkeyKeys.index([invalid], physicalKeys: HotkeyFixtures.laptop, bindings: [:])
        #expect(index.byKey.isEmpty)
        #expect(index.unplaced.isEmpty)
    }
}

@Suite struct SpareKeyTests {
    private func spare(
        _ keys: [KarabinerEvent], _ pairs: [(String, String)] = [], gameKeys: Set<KarabinerEvent> = [],
        hotkeys: [HotkeyBinding] = []
    ) -> KarabinerEvent? {
        HotkeyKeys.spareKey(
            physicalKeys: keys, bindings: HotkeyFixtures.bindings(pairs), gameKeys: gameKeys, hotkeys: hotkeys)
    }

    @Test func f20IsTheFirstChoiceOnEitherKeyboard() {
        #expect(spare(HotkeyFixtures.laptop) == .key("f20"))
        #expect(spare(HotkeyFixtures.fullSize) == .key("f20"))
    }

    @Test func aTakenF20MovesTheChoiceToF19() {
        #expect(spare(HotkeyFixtures.laptop, hotkeys: [HotkeyFixtures.hotkey("f20", .option)]) == .key("f19"))
        #expect(spare(HotkeyFixtures.laptop, [("caps_lock", "f20")]) == .key("f19"))
    }

    @Test func aFullSizeKeyboardHasNoneOnceF20IsTaken() {
        // F13–F19 are drawn on a full-size keyboard.
        #expect(spare(HotkeyFixtures.fullSize, hotkeys: [HotkeyFixtures.hotkey("f20")]) == nil)
    }

    @Test func aKeyMinecraftBindsIsSkipped() {
        #expect(spare(HotkeyFixtures.laptop, gameKeys: [.key("f20")]) == .key("f19"))
        // Under another name of the same key, too: F13 is also Print Screen.
        let hotkeys = (14...20).map { HotkeyFixtures.hotkey("f\($0)") }
        #expect(spare(HotkeyFixtures.laptop, gameKeys: [.key("print_screen")], hotkeys: hotkeys) == nil)
    }

    @Test func noneWhenEveryCandidateIsTaken() {
        let hotkeys = (13...20).map { HotkeyFixtures.hotkey("f\($0)", .shift) }
        #expect(spare(HotkeyFixtures.laptop, hotkeys: hotkeys) == nil)
    }
}
