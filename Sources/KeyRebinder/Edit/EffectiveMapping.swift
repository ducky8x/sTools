/// What a key really produces once Karabiner has applied the profile.
public struct EffectiveBinding: Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        /// A Simple Modification, from the device's own list or the profile's.
        case simple(RebindScope)
        /// A complex-modification rule (index into `complex_modifications.rules`).
        case complex(ruleIndex: Int, description: String)
    }

    public var source: Source
    /// The key the physical key finally produces; `nil` when it cannot be stated as one key.
    public var output: KarabinerEvent?
    /// False when the key is driven by something the plate cannot draw as "this key sends that key": conditions,
    /// modifiers, several events, tap/hold/delay behavior, simultaneous keys.
    public var isDrawable: Bool
}

/// Computes the effective output of every remapped key the way Karabiner's event pipeline does: Simple
/// Modifications first (the device's own entries ahead of the profile's, the last entry for a repeated `from`
/// winning), then Complex Modifications top to bottom with the first manipulator that reacts to the key winning.
/// Each stage runs once on the previous stage's output, so a swap (a to b, b to a) stays a swap and no loop can
/// form. fn function keys depend on the fn modifier and are not part of this table.
public enum EffectiveMapping {
    private struct SimpleHit {
        let scope: RebindScope
        let to: KarabinerEvent
    }

    private struct ComplexHit {
        let ruleIndex: Int
        let description: String
        let shape: ManipulatorShape
    }

    /// Only keys whose output differs from themselves, or that a complex rule takes over, appear in the result.
    public static func bindings(
        in config: JSONValue, profile: String, scope: RebindScope = .allDevices
    ) -> [KarabinerEvent: EffectiveBinding] {
        guard let profileJSON = ConfigAccess.profile(in: config, named: profile) else { return [:] }
        let simple = simpleHits(profileJSON, scope: scope)
        let complex = complexHits(profileJSON)

        var result: [KarabinerEvent: EffectiveBinding] = [:]
        for key in Set(simple.keys).union(complex.keys) {
            var current = key
            var source: EffectiveBinding.Source?
            if let hit = simple[key] {
                guard hit.to.isPlainEvent else {
                    result[key] = EffectiveBinding(source: .simple(hit.scope), output: nil, isDrawable: false)
                    continue
                }
                current = hit.to
                source = .simple(hit.scope)
            }
            if let hit = complex[current] {
                let complexSource = EffectiveBinding.Source.complex(ruleIndex: hit.ruleIndex, description: hit.description)
                guard case .plain(_, let to) = hit.shape else {
                    result[key] = EffectiveBinding(source: complexSource, output: nil, isDrawable: false)
                    continue
                }
                current = to
                source = complexSource
            }
            if let source, current != key {
                result[key] = EffectiveBinding(source: source, output: current, isDrawable: true)
            }
        }
        return result
    }

    private static func simpleHits(_ profile: JSONValue, scope: RebindScope) -> [KarabinerEvent: SimpleHit] {
        var scopes: [RebindScope] = []
        if case .device = scope { scopes.append(scope) }
        scopes.append(.allDevices)
        var hits: [KarabinerEvent: SimpleHit] = [:]
        for scope in scopes {
            guard let list = ConfigAccess.list(in: profile, scope: scope, key: RebindEditor.simpleModificationsKey) else { continue }
            for entry in EntryList.entries(list) where !entry.isOverridden && hits[entry.from] == nil {
                hits[entry.from] = SimpleHit(scope: scope, to: entry.to)
            }
        }
        return hits
    }

    private static func complexHits(_ profile: JSONValue) -> [KarabinerEvent: ComplexHit] {
        var hits: [KarabinerEvent: ComplexHit] = [:]
        let rules = profile["complex_modifications"]?["rules"]?.arrayValue ?? []
        for (ruleIndex, rule) in rules.enumerated() where rule["enabled"]?.boolValue != false {
            let description = rule["description"]?.stringValue ?? ""
            for manipulator in rule["manipulators"]?.arrayValue ?? [] {
                let shape = ManipulatorShape.classify(manipulator)
                let reactsTo: [KarabinerEvent]
                switch shape {
                case .plain(let from, _): reactsTo = [from]
                case .complex(let affected): reactsTo = affected
                }
                for event in reactsTo where hits[event] == nil {
                    hits[event] = ComplexHit(ruleIndex: ruleIndex, description: description, shape: shape)
                }
            }
        }
        return hits
    }
}

extension EffectiveMapping {
    /// What a physical key finally produces under `bindings`: itself when nothing remaps it, `nil` when a rule
    /// drives it in a way that can't be stated as one key. A rebind written under another name of the same key
    /// (`left_alt` for `left_option`) counts.
    public static func output(
        of key: KarabinerEvent, in bindings: [KarabinerEvent: EffectiveBinding], table: KeyTable = .shared
    ) -> KarabinerEvent? {
        guard let binding = table.aliases(of: key).lazy.compactMap({ bindings[$0] }).first else { return key }
        return binding.isDrawable ? binding.output : nil
    }
}
