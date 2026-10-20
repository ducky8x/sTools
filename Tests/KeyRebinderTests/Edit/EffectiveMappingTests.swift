import Testing
@testable import KeyRebinder

private func bindings(
    simple: [(String, String)] = [], devices: String? = nil, rules: [String] = [], scope: RebindScope = .allDevices
) -> [KarabinerEvent: EffectiveBinding] {
    let list = simple.isEmpty ? nil : "[\(simple.map { TestConfig.pair($0.0, $0.1) }.joined(separator: ", "))]"
    let config = TestConfig.profile(simple: list, devices: devices, rules: rules.isEmpty ? nil : "[\(rules.joined(separator: ", "))]")
    return EffectiveMapping.bindings(in: config, profile: "P", scope: scope)
}

private func complex(_ rule: Int, _ description: String) -> EffectiveBinding.Source {
    .complex(ruleIndex: rule, description: description)
}

private let keyboardDevice = """
[{ "identifiers": { "is_keyboard": true, "product_id": 834, "vendor_id": 1452 },
   "simple_modifications": [\(TestConfig.pair("a", "c")), \(TestConfig.pair("m", "n"))] }]
"""

@Suite struct SimpleStageTests {
    @Test func nothingConfiguredMeansNothingChanges() {
        #expect(bindings().isEmpty)
        #expect(EffectiveMapping.bindings(in: TestConfig.fixture("minimal"), profile: "Default profile").isEmpty)
        #expect(EffectiveMapping.bindings(in: TestConfig.fixture("minimal"), profile: "Nope").isEmpty)
    }

    @Test func aSimpleRebindIsDrawable() {
        let result = bindings(simple: [("caps_lock", "escape")])
        #expect(result == [.key("caps_lock"): EffectiveBinding(source: .simple(.allDevices), output: .key("escape"), isDrawable: true)])
    }

    @Test func theLastDuplicateWins() {
        let result = bindings(simple: [("a", "b"), ("a", "c")])
        #expect(result[.key("a")]?.output == .key("c"))
    }

    @Test func aSwapStaysASwap() {
        let result = bindings(simple: [("a", "b"), ("b", "a")])
        #expect(result[.key("a")]?.output == .key("b"))
        #expect(result[.key("b")]?.output == .key("a"))
    }

    @Test func simpleChainsAreNotFollowed() {
        let result = bindings(simple: [("a", "b"), ("b", "c")])
        #expect(result[.key("a")]?.output == .key("b"))
        #expect(result[.key("b")]?.output == .key("c"))
    }

    @Test func aKeyBoundToItselfDoesNothing() {
        #expect(bindings(simple: [("a", "a")]).isEmpty)
    }

    @Test func disablingAKeyShowsVkNone() {
        let result = bindings(simple: [("a", "vk_none")])
        #expect(result[.key("a")] == EffectiveBinding(source: .simple(.allDevices), output: .key("vk_none"), isDrawable: true))
    }

    @Test func mouseButtonsAndOtherKindsWork() {
        let config = TestConfig.parse("""
        { "profiles": [{ "name": "P", "simple_modifications": [
            { "from": { "pointing_button": "button4" }, "to": [{ "key_code": "v" }] },
            { "from": { "key_code": "f13" }, "to": [{ "pointing_button": "button5" }] },
            { "from": { "key_code": "f14" }, "to": [{ "apple_vendor_keyboard_key_code": "spotlight" }] },
            { "from": { "apple_vendor_keyboard_key_code": "launchpad" }, "to": [{ "key_code": "f15" }] }
        ] }] }
        """)
        let result = EffectiveMapping.bindings(in: config, profile: "P")
        #expect(result[.pointing("button4")]?.output == .key("v"))
        #expect(result[.key("f13")]?.output == .pointing("button5"))
        #expect(result[.key("f14")]?.output == .other(["apple_vendor_keyboard_key_code": "spotlight"]))
        #expect(result[.key("f14")]?.isDrawable == true)
        #expect(result[.other(["apple_vendor_keyboard_key_code": "launchpad"])]?.output == .key("f15"))
    }

    @Test func unusualTargetsAreNotDrawable() {
        let config = TestConfig.parse("""
        { "profiles": [{ "name": "P", "simple_modifications": [
            { "from": { "key_code": "a" }, "to": [{ "key_code": "b" }, { "key_code": "c" }] },
            { "from": { "key_code": "d" }, "to": [{ "key_code": "e", "modifiers": ["left_shift"] }] },
            { "from": { "key_code": "f" }, "to": [{ "shell_command": "open -a Safari" }] }
        ] }] }
        """)
        let result = EffectiveMapping.bindings(in: config, profile: "P")
        for key in ["a", "d", "f"] {
            #expect(result[.key(key)] == EffectiveBinding(source: .simple(.allDevices), output: nil, isDrawable: false))
        }
    }
}

@Suite struct DeviceScopeEffectiveTests {
    @Test func theDeviceEntryBeatsTheProfileEntryForThatDevice() {
        let result = bindings(simple: [("a", "b"), ("x", "y")], devices: keyboardDevice, scope: .device(TestConfig.keyboard))
        #expect(result[.key("a")] == EffectiveBinding(source: .simple(.device(TestConfig.keyboard)), output: .key("c"), isDrawable: true))
        #expect(result[.key("m")]?.output == .key("n"))
        #expect(result[.key("x")] == EffectiveBinding(source: .simple(.allDevices), output: .key("y"), isDrawable: true))
    }

    @Test func allDevicesIgnoresDeviceEntries() {
        let result = bindings(simple: [("a", "b")], devices: keyboardDevice)
        #expect(result.count == 1)
        #expect(result[.key("a")]?.output == .key("b"))
    }

    @Test func aDeviceWithoutAnEntryUsesTheProfileList() {
        let result = bindings(simple: [("a", "b")], devices: keyboardDevice, scope: .device(TestConfig.mouse))
        #expect(result == [.key("a"): EffectiveBinding(source: .simple(.allDevices), output: .key("b"), isDrawable: true)])
    }

    @Test func complexRulesApplyToEveryDevice() {
        let rules = [TestConfig.rule("Q to W", TestConfig.swap("q", "w"))]
        let all = bindings(rules: rules)
        let device = bindings(rules: rules, scope: .device(TestConfig.keyboard))
        #expect(all == device)
        #expect(all[.key("q")]?.source == complex(0, "Q to W"))
    }

    @Test func aDeviceRebindFeedsTheComplexStage() {
        let rules = [TestConfig.rule("C to D", TestConfig.swap("c", "d"))]
        let result = bindings(devices: keyboardDevice, rules: rules, scope: .device(TestConfig.keyboard))
        #expect(result[.key("a")] == EffectiveBinding(source: complex(0, "C to D"), output: .key("d"), isDrawable: true))
    }
}

@Suite struct ComplexStageTests {
    @Test func aPlainBasicManipulatorIsDrawableAndKeepsItsRule() {
        let result = bindings(rules: [TestConfig.rule("Skip", TestConfig.swap("a", "b")), TestConfig.rule("Next", TestConfig.swap("c", "d"))])
        #expect(result[.key("c")] == EffectiveBinding(source: complex(1, "Next"), output: .key("d"), isDrawable: true))
        #expect(result.count == 2)
    }

    @Test func theFirstMatchWinsAcrossManipulatorsAndRules() {
        let inOneRule = bindings(rules: [TestConfig.rule("R", TestConfig.swap("x", "y"), TestConfig.swap("x", "z"))])
        #expect(inOneRule[.key("x")]?.output == .key("y"))
        let acrossRules = bindings(rules: [TestConfig.rule("One", TestConfig.swap("x", "y")), TestConfig.rule("Two", TestConfig.swap("x", "z"))])
        #expect(acrossRules[.key("x")]?.source == complex(0, "One"))
        #expect(acrossRules[.key("x")]?.output == .key("y"))
    }

    @Test func aFirstMatchWithConditionsHidesTheLaterPlainOne() {
        let conditional = """
        { "type": "basic", "conditions": [{ "type": "frontmost_application_if", "bundle_identifiers": ["a"] }],
          "from": { "key_code": "x" }, "to": [{ "key_code": "y" }] }
        """
        let result = bindings(rules: [TestConfig.rule("Conditional", conditional), TestConfig.rule("Plain", TestConfig.swap("x", "z"))])
        #expect(result[.key("x")] == EffectiveBinding(source: complex(0, "Conditional"), output: nil, isDrawable: false))
    }

    @Test func complexStageRunsOnceSoSwapsAndCyclesTerminate() {
        let result = bindings(rules: [TestConfig.rule("Cycle", TestConfig.swap("x", "y"), TestConfig.swap("y", "z"), TestConfig.swap("z", "x"))])
        #expect(result[.key("x")]?.output == .key("y"))
        #expect(result[.key("y")]?.output == .key("z"))
        #expect(result[.key("z")]?.output == .key("x"))
    }

    @Test func emptyConditionsAndDescriptionsStayPlain() {
        let manipulator = """
        { "type": "basic", "description": "note", "conditions": [], "parameters": { "basic.to_if_alone_timeout_milliseconds": 100 },
          "from": { "key_code": "a", "modifiers": { "mandatory": [], "optional": ["any"] } }, "to": [{ "key_code": "b" }] }
        """
        let result = bindings(rules: [TestConfig.rule("Plain", manipulator)])
        #expect(result[.key("a")]?.isDrawable == true)
    }

    @Test(arguments: [
        #"{ "type": "basic", "from": { "key_code": "a" }, "to": [{ "key_code": "b" }], "to_if_alone": [{ "key_code": "c" }] }"#,
        #"{ "type": "basic", "from": { "key_code": "a" }, "to": [{ "key_code": "b" }], "to_if_held_down": [{ "key_code": "c" }] }"#,
        #"{ "type": "basic", "from": { "key_code": "a" }, "to": [{ "key_code": "b" }], "to_after_key_up": [{ "key_code": "c" }] }"#,
        #"{ "type": "basic", "from": { "key_code": "a" }, "to": [{ "key_code": "b" }], "to_delayed_action": { "to_if_invoked": [{ "key_code": "c" }] } }"#,
        #"{ "type": "basic", "from": { "key_code": "a" }, "to": [{ "key_code": "b" }, { "key_code": "c" }] }"#,
        #"{ "type": "basic", "from": { "key_code": "a" }, "to": [{ "key_code": "b", "modifiers": ["left_shift"] }] }"#,
        #"{ "type": "basic", "from": { "key_code": "a" }, "to": [{ "key_code": "b", "lazy": true }] }"#,
        #"{ "type": "basic", "from": { "key_code": "a" }, "to": [{ "shell_command": "ls" }] }"#,
        #"{ "type": "basic", "from": { "key_code": "a" }, "to": [{ "set_variable": { "name": "x", "value": 1 } }] }"#,
        #"{ "type": "basic", "from": { "key_code": "a" } }"#,
        #"{ "type": "basic", "from": { "key_code": "a", "modifiers": { "mandatory": ["left_shift"] } }, "to": [{ "key_code": "b" }] }"#,
        #"{ "type": "basic", "from": { "key_code": "a", "modifiers": { "mandatory": ["any"] } }, "to": [{ "key_code": "b" }] }"#,
        #"{ "type": "basic", "from": { "key_code": "a" }, "to": [{ "key_code": "b" }], "conditions": [{ "type": "variable_if", "name": "x", "value": 1 }] }"#,
        #"{ "from": { "key_code": "a" }, "to": [{ "key_code": "b" }] }"#,
        #"{ "type": "other", "from": { "key_code": "a" }, "to": [{ "key_code": "b" }] }"#,
        #"{ "type": "basic", "from": { "key_code": "a" }, "to": [{ "key_code": "b" }], "halt": true }"#,
    ])
    func behaviorBeyondOneToOneMarksTheKeyComplex(manipulator: String) {
        let result = bindings(rules: [TestConfig.rule("Fancy", manipulator)])
        #expect(result[.key("a")] == EffectiveBinding(source: complex(0, "Fancy"), output: nil, isDrawable: false))
    }

    @Test func simultaneousKeysMarkEveryKeyInvolved() {
        let manipulator = """
        { "type": "basic", "from": { "simultaneous": [{ "key_code": "j" }, { "key_code": "k" }] }, "to": [{ "key_code": "l" }] }
        """
        let result = bindings(rules: [TestConfig.rule("Chord", manipulator)])
        #expect(Set(result.keys) == [.key("j"), .key("k")])
        #expect(result.values.allSatisfy { $0.source == complex(0, "Chord") && !$0.isDrawable })
    }

    @Test func manipulatorsWithoutAKeyAddNothing() {
        let anyKey = #"{ "type": "basic", "from": { "any": "key_code" }, "to": [{ "key_code": "b" }] }"#
        let mouse = #"{ "type": "mouse_basic", "flip": ["x"] }"#
        #expect(bindings(rules: [TestConfig.rule("Any", anyKey), TestConfig.rule("Mouse", mouse)]).isEmpty)
    }

    @Test func disabledAndScriptedRulesAreSkippedButStillCountForIndexes() {
        let disabled = #"{ "description": "Off", "enabled": false, "manipulators": [\#(TestConfig.swap("a", "b"))] }"#
        let scripted = #"{ "description": "JS", "enabled": false, "eval_js": "return {}" }"#
        let result = bindings(rules: [disabled, scripted, TestConfig.rule("On", TestConfig.swap("a", "c"))])
        #expect(result[.key("a")]?.source == complex(2, "On"))
        #expect(result[.key("a")]?.output == .key("c"))
    }

    @Test func aRuleWithoutADescriptionHasAnEmptyOne() {
        let result = bindings(rules: [#"{ "manipulators": [\#(TestConfig.swap("a", "b"))] }"#])
        #expect(result[.key("a")]?.source == complex(0, ""))
    }

    @Test func mouseButtonsWorkInComplexRules() {
        let manipulator = #"{ "type": "basic", "from": { "pointing_button": "button4" }, "to": [{ "key_code": "v" }] }"#
        #expect(bindings(rules: [TestConfig.rule("Side", manipulator)])[.pointing("button4")]?.output == .key("v"))
    }
}

@Suite struct ChainTests {
    @Test func aSimpleOutputRemappedByAComplexRuleShowsTheFinalResult() {
        let result = bindings(simple: [("a", "b")], rules: [TestConfig.rule("B to C", TestConfig.swap("b", "c"))])
        #expect(result[.key("a")] == EffectiveBinding(source: complex(0, "B to C"), output: .key("c"), isDrawable: true))
        #expect(result[.key("b")] == EffectiveBinding(source: complex(0, "B to C"), output: .key("c"), isDrawable: true))
    }

    @Test func aSimpleOutputHandedToAConditionalRuleIsComplex() {
        let manipulator = """
        { "type": "basic", "conditions": [{ "type": "device_if", "identifiers": [] }],
          "from": { "key_code": "b" }, "to": [{ "key_code": "c" }] }
        """
        let result = bindings(simple: [("a", "b")], rules: [TestConfig.rule("Cond", manipulator)])
        #expect(result[.key("a")] == EffectiveBinding(source: complex(0, "Cond"), output: nil, isDrawable: false))
    }

    @Test func aComplexRuleOnTheOriginalKeyNeverSeesARebindKey() {
        let result = bindings(simple: [("caps_lock", "escape")], rules: [TestConfig.rule("Caps", TestConfig.swap("caps_lock", "left_control"))])
        #expect(result[.key("caps_lock")] == EffectiveBinding(source: .simple(.allDevices), output: .key("escape"), isDrawable: true))
    }

    @Test func aChainThatEndsWhereItStartedShowsNothingForTheStartingKey() {
        let result = bindings(simple: [("a", "b")], rules: [TestConfig.rule("Back", TestConfig.swap("b", "a"))])
        #expect(result[.key("a")] == nil)
        #expect(result[.key("b")]?.output == .key("a"))
    }

    @Test func anIdentitySimpleEntryStillLetsTheComplexRuleApply() {
        let result = bindings(simple: [("a", "a")], rules: [TestConfig.rule("A to C", TestConfig.swap("a", "c"))])
        #expect(result[.key("a")] == EffectiveBinding(source: complex(0, "A to C"), output: .key("c"), isDrawable: true))
    }

    @Test func aComplexRuleThatReturnsTheKeyToItselfDrawsNothing() {
        #expect(bindings(rules: [TestConfig.rule("Same", TestConfig.swap("a", "a"))]).isEmpty)
    }

    @Test func nonDrawableSimpleOutputsStopTheChain() {
        let config = TestConfig.parse("""
        { "profiles": [{ "name": "P",
            "simple_modifications": [{ "from": { "key_code": "a" }, "to": [{ "key_code": "b" }, { "key_code": "c" }] }],
            "complex_modifications": { "rules": [{ "description": "R", "manipulators": [\(TestConfig.swap("b", "d"))] }] } }] }
        """)
        let result = EffectiveMapping.bindings(in: config, profile: "P")
        #expect(result[.key("a")] == EffectiveBinding(source: .simple(.allDevices), output: nil, isDrawable: false))
    }
}

@Suite struct EffectiveFixtureTests {
    @Test func theTypicalProfileInEveryScope() {
        let config = TestConfig.fixture("typical")
        let all = EffectiveMapping.bindings(in: config, profile: "Default profile")
        #expect(Set(all.keys) == [.key("caps_lock"), .key("f13"), .key("right_command"), .key("grave_accent_and_tilde")])
        #expect(all[.key("caps_lock")] == EffectiveBinding(source: .simple(.allDevices), output: .key("escape"), isDrawable: true))
        #expect(all[.key("f13")]?.output == .pointing("button5"))
        #expect(all[.key("right_command")] == EffectiveBinding(
            source: complex(1, "Right Command to F3 in Minecraft"), output: nil, isDrawable: false))
        #expect(all[.key("grave_accent_and_tilde")]?.isDrawable == false)

        let keyboard = EffectiveMapping.bindings(in: config, profile: "Default profile", scope: .device(TestConfig.keyboard))
        #expect(keyboard[.key("left_option")] == EffectiveBinding(
            source: .simple(.device(TestConfig.keyboard)), output: .key("left_command"), isDrawable: true))
        #expect(keyboard.count == 5)

        let mouse = EffectiveMapping.bindings(in: config, profile: "Default profile", scope: .device(TestConfig.mouse))
        #expect(mouse[.pointing("button4")]?.output == .key("v"))

        #expect(EffectiveMapping.bindings(in: config, profile: "Plain keyboard").isEmpty)
        let macros = EffectiveMapping.bindings(in: config, profile: "Macros")
        #expect(macros[.key("tab")] == EffectiveBinding(source: complex(0, "Hold Tab for sprint"), output: nil, isDrawable: false))
    }

    @Test func theRulesFixture() {
        let result = EffectiveMapping.bindings(in: TestConfig.fixture("kredit-rules"), profile: "Rules")
        #expect(result[.key("f1")] == EffectiveBinding(source: complex(0, "Swap F1 and F2"), output: .key("f2"), isDrawable: true))
        #expect(result[.key("f2")]?.output == .key("f1"))
        #expect(result[.key("a")] == nil)
        #expect(result[.key("c")] == EffectiveBinding(source: complex(3, "Needs shift"), output: nil, isDrawable: false))
        #expect(result[.key("j")]?.source == complex(4, "Both at once"))
        #expect(result[.key("k")]?.source == complex(4, "Both at once"))
        #expect(result[.pointing("button4")]?.output == .key("v"))
        #expect(result.count == 6)
    }

    @Test(arguments: FixtureLoader.names)
    func everyFixtureProfileComputes(fixture: String) {
        let config = TestConfig.fixture(fixture)
        for name in RebindEditor.profileNames(in: config) {
            let result = EffectiveMapping.bindings(in: config, profile: name)
            #expect(result.values.allSatisfy { $0.isDrawable == ($0.output != nil) })
        }
    }

    @Test func rebindEditorEditsShowUpInTheEffectiveMapping() throws {
        let config = try RebindEditor.setRebind(
            in: TestConfig.fixture("minimal"), profile: "Default profile", from: .key("caps_lock"), to: .key("escape"))
        let result = EffectiveMapping.bindings(in: config, profile: "Default profile")
        #expect(result[.key("caps_lock")]?.output == .key("escape"))
    }
}
