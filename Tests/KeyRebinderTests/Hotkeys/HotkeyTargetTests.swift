import Testing
@testable import KeyRebinder

@Suite struct HotkeyTargetTests {
    private func target(
        _ key: KarabinerEvent, _ pairs: [(String, String)] = [], simple: [String] = [], rules: [String] = []
    ) -> HotkeyTarget {
        HotkeyTarget.of(key, bindings: HotkeyFixtures.bindings(pairs, simple: simple, rules: rules))
    }

    // MARK: Keys that can carry a hotkey

    @Test func aKeyThatSendsItselfCarriesItsOwnKeyCode() {
        #expect(target(.key("a")) == .key(sends: .key("a"), keyCode: 0))
        #expect(target(.key("keypad_1")) == .key(sends: .key("keypad_1"), keyCode: 83))
    }

    @Test func aRebindHandsTheKeyItsOutput() {
        #expect(target(.key("caps_lock"), [("caps_lock", "f18")]) == .key(sends: .key("f18"), keyCode: 79))
    }

    @Test func aRebindWrittenUnderTheKeysOtherNameIsFound() {
        #expect(target(.key("left_option"), [("left_alt", "f15")]) == .key(sends: .key("f15"), keyCode: 113))
    }

    @Test func aOneToOneRuleIsFollowed() {
        let rule = TestConfig.rule("Caps to F16", TestConfig.swap("caps_lock", "f16"))
        #expect(target(.key("caps_lock"), rules: [rule]) == .key(sends: .key("f16"), keyCode: 106))
    }

    @Test func aMouseButtonRebindToAKeyCarriesThatKey() {
        let rebind = HotkeyFixtures.buttonPair("button4", "f20")
        #expect(target(.pointing("button4"), simple: [rebind]) == .key(sends: .key("f20"), keyCode: 90))
    }

    // MARK: Keys that can't

    @Test func modifierKeysCantCarryAHotkey() {
        for code in ["caps_lock", "right_option", "fn"] {
            #expect(target(.key(code)) == .modifier(sends: .key(code)))
        }
        #expect(target(.key("a"), [("a", "left_control")]) == .modifier(sends: .key("left_control")))
    }

    @Test func mouseButtonsCantCarryAHotkey() {
        #expect(target(.pointing("button4")) == .mouseButton(sends: .pointing("button4")))
        let rebind = #"{ "from": { "key_code": "f" }, "to": [{ "pointing_button": "button4" }] }"#
        #expect(target(.key("f"), simple: [rebind]) == .mouseButton(sends: .pointing("button4")))
    }

    @Test func outputsWithoutAVirtualKeyCantCarryAHotkey() {
        let volume = HotkeyFixtures.toList("caps_lock", #"[{ "consumer_key_code": "volume_increment" }]"#)
        #expect(target(.key("caps_lock"), simple: [volume]) == .unsupported(sends: .consumer("volume_increment")))
        #expect(target(.key("caps_lock"), [("caps_lock", "mission_control")]) == .unsupported(sends: .key("mission_control")))
        #expect(target(.key("caps_lock"), [("caps_lock", "f21")]) == .unsupported(sends: .key("f21")))
    }

    @Test func aDisabledKeyIsDisabled() {
        #expect(target(.key("caps_lock"), [("caps_lock", "vk_none")]) == .disabled)
    }

    @Test func aSimpleRebindToSeveralKeysSendsSeveralKeys() {
        let two = HotkeyFixtures.toList("caps_lock", #"[{ "key_code": "a" }, { "key_code": "b" }]"#)
        #expect(target(.key("caps_lock"), simple: [two]) == .severalKeys)
        let combination = HotkeyFixtures.toList("caps_lock", #"[{ "key_code": "f3", "modifiers": ["left_shift"] }]"#)
        #expect(target(.key("caps_lock"), simple: [combination]) == .severalKeys)
    }

    @Test func aTapHoldRuleDrivesTheKey() {
        let rule = HotkeyFixtures.tapHoldRule("caps_lock", held: "left_control", alone: "escape")
        #expect(target(.key("caps_lock"), rules: [rule]) == .ruleDriven)
    }

    @Test func outputsAreClassifiedOnTheirOwn() {
        #expect(HotkeyTarget.of(output: .key("vk_none")) == .disabled)
        #expect(HotkeyTarget.of(output: .key("left_alt")) == .modifier(sends: .key("left_alt")))
        #expect(HotkeyTarget.of(output: .pointing("button1")) == .mouseButton(sends: .pointing("button1")))
        #expect(HotkeyTarget.of(output: .key("print_screen")) == .key(sends: .key("print_screen"), keyCode: 105))
        #expect(HotkeyTarget.of(output: .key("dashboard")) == .unsupported(sends: .key("dashboard")))
    }
}
