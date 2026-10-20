import Testing
@testable import KeyRebinder

private let physicalKeys = KeyboardLayout(shape: .ansi, formFactor: .laptop).keys.map(\.event) + MouseLayout.buttons.map(\.event)

private func findings(
    simple: [String] = [], rules: [String] = [], keybinds: String? = nil, speedrun: Bool = true
) -> [CheckerFinding] {
    let config = TestConfig.profile(
        simple: simple.isEmpty ? nil : "[\(simple.joined(separator: ", "))]",
        rules: rules.isEmpty ? nil : "[\(rules.joined(separator: ", "))]")
    let context = RuleChecker.Context(
        physicalKeys: physicalKeys,
        minecraftKeybinds: keybinds.map { MinecraftKeybinds.parse(optionsText: $0) },
        includesSpeedrunRules: speedrun)
    return RuleChecker.findings(in: config, profile: "P", context: context)
}

private func of(_ kind: CheckerFinding.Kind, _ all: [CheckerFinding]) -> [CheckerFinding] {
    all.filter { $0.kind == kind }
}

private func toList(_ from: String, _ to: String) -> String {
    "{ \"from\": { \"key_code\": \"\(from)\" }, \"to\": \(to) }"
}

/// Default 1.16.1 binds that matter here: attack on the left button, sprint on Left Control.
private let defaultBinds = """
key_key.attack:key.mouse.left
key_key.use:key.mouse.right
key_key.sprint:key.keyboard.left.control
key_key.forward:key.keyboard.w
"""

@Suite struct KarabinerConflictTests {
    @Test func aRepeatedFromIsADuplicate() {
        let result = of(.duplicateRebind, findings(simple: [TestConfig.pair("a", "b"), TestConfig.pair("a", "c")]))
        #expect(result.count == 1)
        #expect(result.first?.keys == [.key("a")])
        #expect(result.first?.message == "A is rebound more than once; only the last entry, to C, applies.")
    }

    @Test func distinctFromsAreNotDuplicates() {
        #expect(of(.duplicateRebind, findings(simple: [TestConfig.pair("a", "b"), TestConfig.pair("c", "d")])).isEmpty)
    }

    @Test func aCatchAllRuleShadowsALaterOne() {
        let first = TestConfig.rule("Caps to Esc", """
            { "type": "basic", "from": { "key_code": "caps_lock", "modifiers": { "optional": ["any"] } }, "to": [{ "key_code": "escape" }] }
            """)
        let second = TestConfig.rule("Caps to Tab", TestConfig.swap("caps_lock", "tab"))
        let result = of(.shadowedRule, findings(rules: [first, second]))
        #expect(result.map(\.keys) == [[.key("caps_lock")]])
        #expect(result.first?.message == "Rule \u{201C}Caps to Tab\u{201D} never runs for Caps Lock: rule \u{201C}Caps to Esc\u{201D} above it always handles Caps Lock first.")
    }

    @Test func anIdenticalFromInTheSameRuleIsShadowed() {
        let rule = TestConfig.rule("Twice", TestConfig.swap("a", "b"), TestConfig.swap("a", "c"))
        let result = of(.shadowedRule, findings(rules: [rule]))
        #expect(result.first?.message.hasPrefix("Part of rule \u{201C}Twice\u{201D}") == true)
    }

    @Test func conditionsModifiersAndDisabledRulesDoNotShadow() {
        let conditional = TestConfig.rule("Only in Terminal", """
            { "type": "basic", "from": { "key_code": "a", "modifiers": { "optional": ["any"] } }, "to": [{ "key_code": "b" }],
              "conditions": [{ "type": "frontmost_application_if", "bundle_identifiers": ["^com\\\\.apple\\\\.Terminal$"] }] }
            """)
        let withShift = TestConfig.rule("Shift A", """
            { "type": "basic", "from": { "key_code": "c", "modifiers": { "mandatory": ["shift"] } }, "to": [{ "key_code": "d" }] }
            """)
        let disabled = "{ \"description\": \"Off\", \"enabled\": false, \"manipulators\": [\(TestConfig.swap("e", "f"))] }"
        let later = TestConfig.rule("Later", TestConfig.swap("a", "x"), TestConfig.swap("c", "y"), TestConfig.swap("e", "z"))
        #expect(of(.shadowedRule, findings(rules: [conditional, withShift, disabled, later])).isEmpty)
    }

    @Test func aRebindChangedAgainByARuleIsChained() {
        let result = of(.chainedRebind, findings(
            simple: [TestConfig.pair("caps_lock", "f13")], rules: [TestConfig.rule("F13 to Esc", TestConfig.swap("f13", "escape"))]))
        #expect(result.map(\.keys) == [[.key("caps_lock")]])
        #expect(result.first?.message == "Caps Lock \u{2192} F13 is changed again by rule \u{201C}F13 to Esc\u{201D}, so Caps Lock ends up as Esc.")
    }

    @Test func aRebindNoRuleTouchesIsNotChained() {
        #expect(of(.chainedRebind, findings(simple: [TestConfig.pair("caps_lock", "f13")])).isEmpty)
    }

    @Test func aMissingProfileHasNoFindings() {
        let context = RuleChecker.Context(physicalKeys: physicalKeys, minecraftKeybinds: nil)
        #expect(RuleChecker.findings(in: TestConfig.profile(), profile: "Nope", context: context).isEmpty)
    }
}

@Suite struct OneKeyOneInputTests {
    @Test func aKeyThatSendsACombinationBreaksTheRule() {
        let result = of(.oneKeyOneInput, findings(simple: [toList("a", #"[{ "key_code": "f3", "modifiers": ["left_shift"] }]"#)]))
        #expect(result.map(\.keys) == [[.key("a")]])
        #expect(result.first?.message == "A sends Left Shift+F3 at once; each key may cause only one game input.")
        #expect(result.first?.kind.rule?.number == "A.10.1")
    }

    @Test func aKeyThatSendsTwoKeysBreaksTheRule() {
        #expect(of(.oneKeyOneInput, findings(simple: [toList("a", #"[{ "key_code": "b" }, { "key_code": "c" }]"#)])).count == 1)
    }

    @Test func aRuleThatSendsTwoKeysBreaksTheRule() {
        let rule = TestConfig.rule("Double", #"{ "type": "basic", "from": { "key_code": "q" }, "to": [{ "key_code": "w" }, { "key_code": "e" }] }"#)
        let result = of(.oneKeyOneInput, findings(rules: [rule]))
        #expect(result.first?.message == "Rule \u{201C}Double\u{201D} makes Q send W and E at once; each key may cause only one game input.")
    }

    @Test func withKeybindsOnlyGameInputsCount() {
        let unbound = toList("a", #"[{ "key_code": "f18", "modifiers": ["left_command"] }]"#)
        #expect(of(.oneKeyOneInput, findings(simple: [unbound], keybinds: defaultBinds)).isEmpty)
        let debug = toList("a", #"[{ "key_code": "f3", "modifiers": ["left_shift"] }]"#)
        #expect(of(.oneKeyOneInput, findings(simple: [debug], keybinds: defaultBinds)).count == 1)
    }

    @Test func twoKeysProducingTheSameInputBreakTheRule() {
        let result = of(.oneKeyOneInput, findings(simple: [TestConfig.pair("caps_lock", "left_control")]))
        #expect(result.map(\.keys) == [[.key("caps_lock"), .key("left_control")]])
        #expect(result.first?.message == "Caps Lock and Left Control both produce Left Control; each game input may have only one key.")
    }

    @Test func theMessageNamesTheGameActionWhenKnown() {
        let result = of(.oneKeyOneInput, findings(simple: [TestConfig.pair("caps_lock", "left_control")], keybinds: defaultBinds))
        #expect(result.first?.message == "Caps Lock and Left Control both produce Left Control (Sprint in Minecraft); each game input may have only one key.")
    }

    @Test func aSharedOutputTheGameDoesNotUseIsFineWhenKeybindsAreKnown() {
        #expect(of(.oneKeyOneInput, findings(simple: [TestConfig.pair("caps_lock", "f18")], keybinds: defaultBinds)).isEmpty)
    }

    @Test func swapsAndDisabledKeysAreFine() {
        let swap = [TestConfig.pair("a", "b"), TestConfig.pair("b", "a")]
        #expect(of(.oneKeyOneInput, findings(simple: swap)).isEmpty)
        let disabled = [TestConfig.pair("a", "vk_none"), TestConfig.pair("b", "vk_none")]
        #expect(of(.oneKeyOneInput, findings(simple: disabled)).isEmpty)
    }

    @Test func speedrunFindingsCanBeTurnedOff() {
        let all = findings(simple: [TestConfig.pair("caps_lock", "left_control"), TestConfig.pair("a", "b"), TestConfig.pair("a", "c")], speedrun: false)
        #expect(all.allSatisfy { $0.kind.rule == nil })
        #expect(of(.duplicateRebind, all).count == 1)
    }
}

@Suite struct ButtonsRepeatAndMacroTests {
    @Test func aKeyRemappedToTheScrollWheelBreaksA102() {
        let result = of(.buttonsOnly, findings(simple: [toList("a", #"[{ "mouse_key": { "vertical_wheel": 32 } }]"#)]))
        #expect(result.map(\.keys) == [[.key("a")]])
        #expect(result.first?.message == "A is rebound to the scroll wheel; rebinds must be to buttons.")
    }

    @Test func aRuleThatScrollsBreaksA102() {
        let rule = TestConfig.rule("Side scroll", #"{ "type": "basic", "from": { "pointing_button": "button4" }, "to": [{ "mouse_key": { "horizontal_wheel": -64 } }] }"#)
        #expect(of(.buttonsOnly, findings(rules: [rule])).map(\.keys) == [[.pointing("button4")]])
    }

    @Test func pointerMovementIsNotScrolling() {
        #expect(of(.buttonsOnly, findings(simple: [toList("a", #"[{ "mouse_key": { "x": 1536 } }]"#)])).isEmpty)
    }

    @Test func aKeyboardKeySendingAttackBreaksA103() {
        let result = of(.noRepeatAbuse, findings(simple: [toList("f", #"[{ "pointing_button": "button1" }]"#)]))
        #expect(result.map(\.keys) == [[.key("f")]])
        #expect(result.first?.message == "F sends Left Click, which Minecraft uses for Attack/Destroy.")
    }

    @Test func attackBoundToAKeyInOptionsBreaksA103() {
        let result = of(.noRepeatAbuse, findings(keybinds: "key_key.attack:key.keyboard.r\nkey_key.use:key.mouse.right"))
        #expect(result.map(\.message) == ["Minecraft\u{2019}s Attack/Destroy is bound to R, a keyboard key."])
    }

    @Test func mouseButtonsSendingAttackAreFine() {
        #expect(of(.noRepeatAbuse, findings(keybinds: defaultBinds)).isEmpty)
        let sideButton = #"{ "from": { "pointing_button": "button4" }, "to": [{ "pointing_button": "button1" }] }"#
        #expect(of(.noRepeatAbuse, findings(simple: [sideButton])).isEmpty)
    }

    @Test func tapHoldRulesAreMacros() {
        let rule = TestConfig.rule("Caps tap/hold", """
            { "type": "basic", "from": { "key_code": "caps_lock" }, "to": [{ "key_code": "left_control" }],
              "to_if_alone": [{ "key_code": "escape" }] }
            """)
        let result = of(.noMacros, findings(rules: [rule]))
        #expect(result.map(\.keys) == [[.key("caps_lock")]])
        #expect(result.first?.message == "Rule \u{201C}Caps tap/hold\u{201D} sends extra keys when tapped on Caps Lock.")
    }

    @Test func delayedAndRepeatedOutputsAreMacros() {
        let delayed = TestConfig.rule("Later", """
            { "type": "basic", "from": { "key_code": "q" }, "to": [{ "key_code": "w" }],
              "to_delayed_action": { "to_if_invoked": [{ "key_code": "e" }] } }
            """)
        let repeated = TestConfig.rule("Spam", #"{ "type": "basic", "from": { "key_code": "r" }, "to": [{ "key_code": "t" }, { "key_code": "t" }] }"#)
        let messages = of(.noMacros, findings(rules: [delayed, repeated])).map(\.message)
        #expect(messages.contains { $0.contains("sends delayed actions") })
        #expect(messages.contains { $0.contains("repeats an input") })
    }

    @Test func plainSwapsAreNotMacros() {
        #expect(of(.noMacros, findings(rules: [TestConfig.rule("Swap", TestConfig.swap("a", "b"))])).isEmpty)
    }

    @Test func withKeybindsAMacroAwayFromTheGameIsIgnored() {
        let rule = TestConfig.rule("Launcher", """
            { "type": "basic", "from": { "key_code": "f18" }, "to": [{ "key_code": "f19" }], "to_if_alone": [{ "key_code": "f20" }] }
            """)
        #expect(of(.noMacros, findings(rules: [rule], keybinds: defaultBinds)).isEmpty)
        #expect(of(.noMacros, findings(rules: [rule])).count == 1)
    }
}
