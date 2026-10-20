/// How one complex-modification manipulator looks to the editor and to the effective-output computation.
enum ManipulatorShape: Equatable {
    /// A basic manipulator that only turns one key into one other key: no conditions, modifiers, extra events or
    /// tap/hold/delay behavior. `from` may carry `modifiers.optional` (Karabiner's usual "any").
    case plain(from: KarabinerEvent, to: KarabinerEvent)
    /// Anything else. `affected` lists the keys it reacts to (empty when that cannot be told, e.g. `"any"`).
    case complex(affected: [KarabinerEvent])

    /// Members a plain manipulator may carry; any other member (`to_if_alone`, `to_after_key_up`, `halt`...) makes it complex.
    private static let ignorableKeys: Set<String> = ["type", "from", "to", "description", "parameters"]

    static func classify(_ manipulator: JSONValue) -> ManipulatorShape {
        guard case .object(let members) = manipulator else { return .complex(affected: []) }
        let affected = affectedEvents(manipulator["from"])
        guard manipulator["type"]?.stringValue == "basic" else { return .complex(affected: affected) }
        let hasNoConditions = manipulator["conditions"].map { $0.arrayValue?.isEmpty == true } ?? true
        let hasOnlyPlainMembers = members.allSatisfy { ignorableKeys.contains($0.key) || ($0.key == "conditions" && hasNoConditions) }
        guard hasOnlyPlainMembers, let from = plainFrom(manipulator["from"]),
              let toList = manipulator["to"]?.arrayValue, toList.count == 1 else { return .complex(affected: affected) }
        let to = KarabinerEvent(json: toList[0])
        guard to.isPlainEvent else { return .complex(affected: affected) }
        return .plain(from: from, to: to)
    }

    /// The single event of a `from` object that has no mandatory modifiers, simultaneous keys or `any`.
    private static func plainFrom(_ from: JSONValue?) -> KarabinerEvent? {
        guard case .object(let members)? = from else { return nil }
        let eventMembers = members.filter { $0.key != "modifiers" }
        guard eventMembers.count == 1, KarabinerEvent.plainEventKeys.contains(eventMembers[0].key) else { return nil }
        if let modifiers = from?["modifiers"] {
            guard modifiers.isObject else { return nil }
            if let mandatory = modifiers["mandatory"], mandatory.arrayValue?.isEmpty != true { return nil }
        }
        return KarabinerEvent(json: .object(eventMembers))
    }

    private static func affectedEvents(_ from: JSONValue?) -> [KarabinerEvent] {
        guard let from else { return [] }
        if let simultaneous = from["simultaneous"]?.arrayValue { return simultaneous.compactMap(event(in:)) }
        return event(in: from).map { [$0] } ?? []
    }

    private static func event(in object: JSONValue) -> KarabinerEvent? {
        guard let members = object.members else { return nil }
        let eventMembers = members.filter { KarabinerEvent.plainEventKeys.contains($0.key) }
        return eventMembers.count == 1 ? KarabinerEvent(json: .object(eventMembers)) : nil
    }
}
