extension KarabinerEvent {
    /// The member names Karabiner accepts for one plain event inside `from` / `to` objects.
    static let plainEventKeys: Set<String> = [
        "key_code", "consumer_key_code", "pointing_button", "apple_vendor_keyboard_key_code",
        "apple_vendor_top_case_key_code", "generic_desktop", "mouse_key", "sticky_modifier", "software_function",
    ]

    /// Reads one event object. An object whose only member is `key_code`, `consumer_key_code` or `pointing_button`
    /// with a string value becomes the matching typed case; everything else is kept verbatim as `.other`.
    public init(json: JSONValue) {
        if case .object(let members) = json, members.count == 1, case .string(let code) = members[0].value {
            switch members[0].key {
            case "key_code": self = .key(code); return
            case "consumer_key_code": self = .consumer(code); return
            case "pointing_button": self = .pointing(code); return
            default: break
            }
        }
        self = .other(json)
    }

    /// Reads the `to` value of a simple modification: a single event, or `.other(.array(...))` when the list does
    /// not hold exactly one event (so nothing is ever dropped). An old-style single object counts as one event.
    public init(toValue: JSONValue) {
        switch toValue {
        case .array(let items) where items.count == 1: self.init(json: items[0])
        case .array: self = .other(toValue)
        default: self.init(json: toValue)
        }
    }

    /// The event as the object Karabiner stores. For a multi-event `.other` this is the array itself.
    public var json: JSONValue {
        switch self {
        case .key(let code): .object([JSONMember("key_code", .string(code))])
        case .consumer(let code): .object([JSONMember("consumer_key_code", .string(code))])
        case .pointing(let code): .object([JSONMember("pointing_button", .string(code))])
        case .other(let value): value
        }
    }

    /// The `to` array that produces this event.
    public var toValue: JSONValue {
        if case .other(.array(let items)) = self { return .array(items) }
        return .array([json])
    }

    /// True for one lone-member event object of a kind Karabiner treats as a key press: nothing attached
    /// (no modifiers, repeat, halt...) and not a command like `shell_command`.
    public var isPlainEvent: Bool {
        switch self {
        case .key, .consumer, .pointing: true
        case .other(.object(let members)): members.count == 1 && Self.plainEventKeys.contains(members[0].key)
        case .other: false
        }
    }
}
