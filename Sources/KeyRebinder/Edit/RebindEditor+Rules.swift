/// One complex-modification rule as the rule list shows it.
public struct RuleSummary: Hashable, Sendable {
    /// Position in the profile's `complex_modifications.rules`.
    public let index: Int
    public let description: String
    /// False when the rule has `"enabled": false`; Karabiner skips it.
    public let isEnabled: Bool
    /// True when the rule has manipulators and every one is a basic one-to-one key swap, so a form can edit it.
    public let isBasicOneToOne: Bool
}

extension RebindEditor {
    public static func rules(in config: JSONValue, profile: String) -> [RuleSummary] {
        ruleList(in: config, profile: profile).enumerated().map { index, rule in
            let manipulators = rule["manipulators"]?.arrayValue ?? []
            let allPlain = !manipulators.isEmpty && manipulators.allSatisfy {
                if case .plain = ManipulatorShape.classify($0) { true } else { false }
            }
            return RuleSummary(
                index: index,
                description: rule["description"]?.stringValue ?? "",
                isEnabled: rule["enabled"]?.boolValue ?? true,
                isBasicOneToOne: allPlain
            )
        }
    }

    /// The full JSON of one rule, for the JSON editor.
    public static func rule(in config: JSONValue, profile: String, at index: Int) -> JSONValue? {
        let rules = ruleList(in: config, profile: profile)
        guard rules.indices.contains(index) else { return nil }
        return rules[index]
    }

    public static func replaceRule(in config: JSONValue, profile: String, at index: Int, with rule: JSONValue) throws -> JSONValue {
        try modifyRules(config, profile: profile) { rules in
            guard rules.indices.contains(index) else { throw EditError.ruleIndexOutOfRange(index) }
            var rules = rules
            rules[index] = rule
            return rules
        }
    }

    public static func deleteRule(in config: JSONValue, profile: String, at index: Int) throws -> JSONValue {
        try modifyRules(config, profile: profile) { rules in
            guard rules.indices.contains(index) else { throw EditError.ruleIndexOutOfRange(index) }
            var rules = rules
            rules.remove(at: index)
            return rules
        }
    }

    /// Moves the rule at `source` so it ends up at index `destination` (rules run top to bottom, first match wins).
    public static func moveRule(in config: JSONValue, profile: String, from source: Int, to destination: Int) throws -> JSONValue {
        try modifyRules(config, profile: profile) { rules in
            for index in [source, destination] where !rules.indices.contains(index) {
                throw EditError.ruleIndexOutOfRange(index)
            }
            var rules = rules
            rules.insert(rules.remove(at: source), at: destination)
            return rules
        }
    }

    /// The one-to-one key swaps of a rule the form can edit, with each manipulator's position in the rule.
    /// Empty unless every manipulator is a plain swap (``RuleSummary/isBasicOneToOne``).
    public static func plainSwaps(in rule: JSONValue) -> [(manipulator: Int, from: KarabinerEvent, to: KarabinerEvent)] {
        let manipulators = rule["manipulators"]?.arrayValue ?? []
        var swaps: [(manipulator: Int, from: KarabinerEvent, to: KarabinerEvent)] = []
        for (index, manipulator) in manipulators.enumerated() {
            guard case .plain(let from, let to) = ManipulatorShape.classify(manipulator) else { return [] }
            swaps.append((index, from, to))
        }
        return swaps
    }

    /// Makes manipulator `manipulator` of rule `index` send `to` instead; every other member is kept.
    public static func setManipulatorOutput(
        in config: JSONValue, profile: String, rule index: Int, manipulator: Int, to: KarabinerEvent
    ) throws -> JSONValue {
        guard let rule = rule(in: config, profile: profile, at: index) else { throw EditError.ruleIndexOutOfRange(index) }
        guard let manipulators = rule["manipulators"]?.arrayValue, manipulators.indices.contains(manipulator) else {
            throw EditError.malformedConfig("rule \(index) has no manipulator \(manipulator)")
        }
        let updated = manipulators[manipulator].setting("to", to.toValue)
        return try replaceRule(in: config, profile: profile, at: index, with: rule.setting("manipulators", .array(
            manipulators.enumerated().map { $0.offset == manipulator ? updated : $0.element })))
    }

    /// Turns a rule on or off. Off is written as `"enabled": false`; on removes the member, as Karabiner does.
    public static func setRuleEnabled(in config: JSONValue, profile: String, at index: Int, enabled: Bool) throws -> JSONValue {
        guard let rule = rule(in: config, profile: profile, at: index) else { throw EditError.ruleIndexOutOfRange(index) }
        return try replaceRule(in: config, profile: profile, at: index, with: rule.setting("enabled", enabled ? nil : .bool(false)))
    }

    /// The `{"title": …, "rules": [rule]}` file `karabiner_cli --lint-complex-modifications` checks.
    public static func lintDocument(for rule: JSONValue) -> JSONValue {
        .object([JSONMember("title", "sTools check"), JSONMember("rules", .array([rule]))])
    }

    private static func ruleList(in config: JSONValue, profile: String) -> [JSONValue] {
        ConfigAccess.profile(in: config, named: profile)?["complex_modifications"]?["rules"]?.arrayValue ?? []
    }

    private static func modifyRules(
        _ config: JSONValue, profile: String, _ transform: ([JSONValue]) throws -> [JSONValue]
    ) throws -> JSONValue {
        try ConfigAccess.updateProfile(config, named: profile) { profileJSON in
            guard let complex = profileJSON["complex_modifications"], let rules = complex["rules"]?.arrayValue else {
                _ = try transform([])
                return profileJSON
            }
            return profileJSON.setting("complex_modifications", complex.setting("rules", .array(try transform(rules))))
        }
    }
}
