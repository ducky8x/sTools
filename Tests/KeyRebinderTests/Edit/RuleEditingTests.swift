import Testing
@testable import KeyRebinder

@Suite struct RuleEditingTests {
    @Test func summarizesTheTypicalRules() {
        let rules = RebindEditor.rules(in: TestConfig.fixture("typical"), profile: "Default profile")
        #expect(rules.map(\.index) == [0, 1])
        #expect(rules.map(\.description) == ["Caps Lock to Control, Escape when tapped", "Right Command to F3 in Minecraft"])
        #expect(rules.map(\.isBasicOneToOne) == [false, false])
        #expect(rules.allSatisfy { $0.isEnabled })
        #expect(RebindEditor.rules(in: TestConfig.fixture("typical"), profile: "Macros").map(\.isBasicOneToOne) == [false])
    }

    @Test func recognizesBasicOneToOneRules() {
        let rules = RebindEditor.rules(in: TestConfig.fixture("kredit-rules"), profile: "Rules")
        #expect(rules.map(\.description) == [
            "Swap F1 and F2", "Disabled rule", "Scripted rule", "Needs shift", "Both at once", "Mouse button to key", "Mouse tweaks",
        ])
        #expect(rules.map(\.isBasicOneToOne) == [true, true, false, false, false, true, false])
        #expect(rules.map(\.isEnabled) == [true, false, false, true, true, true, true])
    }

    @Test func profilesWithoutRulesHaveNone() {
        #expect(RebindEditor.rules(in: TestConfig.fixture("minimal"), profile: "Default profile").isEmpty)
        #expect(RebindEditor.rules(in: TestConfig.fixture("minimal"), profile: "Nope").isEmpty)
    }

    @Test func aRuleWithoutADescriptionReadsAsEmpty() {
        let config = TestConfig.profile(rules: "[{ \"manipulators\": [] }]")
        let rule = RebindEditor.rules(in: config, profile: "P")[0]
        #expect(rule.description == "")
        #expect(!rule.isBasicOneToOne)
    }

    @Test func readsOneRuleForTheJSONEditor() {
        let config = TestConfig.fixture("typical")
        #expect(RebindEditor.rule(in: config, profile: "Default profile", at: 1)?["description"] == "Right Command to F3 in Minecraft")
        #expect(RebindEditor.rule(in: config, profile: "Default profile", at: 2) == JSONValue?.none)
        #expect(RebindEditor.rule(in: config, profile: "Default profile", at: -1) == JSONValue?.none)
    }

    @Test func replacesOneRuleOnly() throws {
        let config = TestConfig.fixture("typical")
        let replacement = TestConfig.parse(TestConfig.rule("New", TestConfig.swap("a", "b")))
        let updated = try RebindEditor.replaceRule(in: config, profile: "Default profile", at: 1, with: replacement)
        #expect(RebindEditor.rule(in: updated, profile: "Default profile", at: 1) == replacement)
        #expect(changedPaths(config, updated).allSatisfy { $0.hasPrefix("profiles[0].complex_modifications.rules[1]") })
        #expect(RebindEditor.rules(in: updated, profile: "Default profile")[1].isBasicOneToOne)
    }

    @Test func deletesOneRuleOnly() throws {
        let config = TestConfig.fixture("typical")
        let updated = try RebindEditor.deleteRule(in: config, profile: "Default profile", at: 0)
        #expect(RebindEditor.rules(in: updated, profile: "Default profile").map(\.description) == ["Right Command to F3 in Minecraft"])
        #expect(changedPaths(config, updated).allSatisfy { $0.hasPrefix("profiles[0].complex_modifications.rules") })
        #expect(updated["profiles"]?[index: 0]?["complex_modifications"]?["parameters"] == config["profiles"]?[index: 0]?["complex_modifications"]?["parameters"])
    }

    @Test func deletingTheLastRuleLeavesAnEmptyList() throws {
        let updated = try RebindEditor.deleteRule(in: TestConfig.fixture("typical"), profile: "Macros", at: 0)
        #expect(updated["profiles"]?[index: 2]?["complex_modifications"]?["rules"] == [])
    }

    @Test func movesARuleToTheGivenIndex() throws {
        let config = TestConfig.fixture("kredit-rules")
        let updated = try RebindEditor.moveRule(in: config, profile: "Rules", from: 0, to: 2)
        #expect(RebindEditor.rules(in: updated, profile: "Rules").map(\.description).prefix(4) == ["Disabled rule", "Scripted rule", "Swap F1 and F2", "Needs shift"])
        let back = try RebindEditor.moveRule(in: updated, profile: "Rules", from: 2, to: 0)
        #expect(back == config)
        #expect(try RebindEditor.moveRule(in: config, profile: "Rules", from: 3, to: 3) == config)
    }

    @Test func rejectsBadIndexesAndProfiles() {
        let config = TestConfig.fixture("typical")
        let rule = TestConfig.parse(TestConfig.rule("x"))
        #expect(throws: EditError.ruleIndexOutOfRange(2)) { try RebindEditor.deleteRule(in: config, profile: "Default profile", at: 2) }
        #expect(throws: EditError.ruleIndexOutOfRange(-1)) { try RebindEditor.replaceRule(in: config, profile: "Default profile", at: -1, with: rule) }
        #expect(throws: EditError.ruleIndexOutOfRange(5)) { try RebindEditor.moveRule(in: config, profile: "Default profile", from: 0, to: 5) }
        #expect(throws: EditError.ruleIndexOutOfRange(0)) { try RebindEditor.deleteRule(in: config, profile: "Plain keyboard", at: 0) }
        #expect(throws: EditError.profileNotFound("Nope")) { try RebindEditor.deleteRule(in: config, profile: "Nope", at: 0) }
    }
}

@Suite struct RuleFormEditingTests {
    let config = TestConfig.fixture("kredit-rules")

    @Test func plainSwapsListEveryManipulatorOfAFormRule() throws {
        let rule = try #require(RebindEditor.rule(in: config, profile: "Rules", at: 0))
        let swaps = RebindEditor.plainSwaps(in: rule)
        #expect(swaps.map(\.manipulator) == [0, 1])
        #expect(swaps.map(\.from) == [.key("f1"), .key("f2")])
        #expect(swaps.map(\.to) == [.key("f2"), .key("f1")])
        let scripted = try #require(RebindEditor.rule(in: config, profile: "Rules", at: 2))
        #expect(RebindEditor.plainSwaps(in: scripted).isEmpty)
    }

    @Test func changingOneOutputTouchesOnlyThatTo() throws {
        let updated = try RebindEditor.setManipulatorOutput(in: config, profile: "Rules", rule: 0, manipulator: 1, to: .key("f5"))
        #expect(changedPaths(config, updated) == ["profiles[0].complex_modifications.rules[0].manipulators[1].to[0].key_code"])
        let rule = try #require(RebindEditor.rule(in: updated, profile: "Rules", at: 0))
        #expect(RebindEditor.plainSwaps(in: rule).map(\.to) == [.key("f2"), .key("f5")])
        // The first manipulator's `modifiers.optional` is untouched.
        #expect(rule["manipulators"]?[index: 0]?["from"]?["modifiers"] != nil)
    }

    @Test func badPositionsAreRefused() {
        #expect(throws: EditError.ruleIndexOutOfRange(40)) {
            try RebindEditor.setManipulatorOutput(in: config, profile: "Rules", rule: 40, manipulator: 0, to: .key("a"))
        }
        #expect(throws: EditError.self) {
            try RebindEditor.setManipulatorOutput(in: config, profile: "Rules", rule: 0, manipulator: 9, to: .key("a"))
        }
    }

    @Test func enablingRemovesTheMemberAndDisablingWritesFalse() throws {
        let enabled = try RebindEditor.setRuleEnabled(in: config, profile: "Rules", at: 1, enabled: true)
        #expect(RebindEditor.rule(in: enabled, profile: "Rules", at: 1)?["enabled"] == nil)
        #expect(RebindEditor.rules(in: enabled, profile: "Rules")[1].isEnabled)
        let disabled = try RebindEditor.setRuleEnabled(in: config, profile: "Rules", at: 0, enabled: false)
        #expect(RebindEditor.rule(in: disabled, profile: "Rules", at: 0)?["enabled"] == .bool(false))
        #expect(changedPaths(config, disabled) == ["profiles[0].complex_modifications.rules[0].enabled"])
    }

    @Test func theLintDocumentWrapsOneRule() throws {
        let rule = try #require(RebindEditor.rule(in: config, profile: "Rules", at: 0))
        let document = RebindEditor.lintDocument(for: rule)
        #expect(document["title"] == "sTools check")
        #expect(document["rules"]?.arrayValue == [rule])
    }
}
