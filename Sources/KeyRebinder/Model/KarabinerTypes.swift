/// One input or output event in Karabiner-Elements' own vocabulary.
public enum KarabinerEvent: Hashable, Sendable {
    /// `key_code`, e.g. "caps_lock", "f3".
    case key(String)
    /// `consumer_key_code`, e.g. "mute", "play_or_pause".
    case consumer(String)
    /// `pointing_button`, e.g. "button1", "button4".
    case pointing(String)
    /// Anything else Karabiner can send (apple vendor keys, software functions...). Kept verbatim and never edited.
    case other(JSONValue)

    /// The JSON key Karabiner uses for this event inside `from` / `to` objects.
    public var jsonKey: String? {
        switch self {
        case .key: "key_code"
        case .consumer: "consumer_key_code"
        case .pointing: "pointing_button"
        case .other: nil
        }
    }

    /// The code string for the three editable kinds.
    public var code: String? {
        switch self {
        case .key(let code), .consumer(let code), .pointing(let code): code
        case .other: nil
        }
    }
}

/// Identifies one connected keyboard or mouse inside a Karabiner profile's `devices` array.
public struct DeviceIdentifiers: Hashable, Sendable, Codable {
    public var vendorID: Int?
    public var productID: Int?
    public var isKeyboard: Bool?
    public var isPointingDevice: Bool?

    public init(vendorID: Int? = nil, productID: Int? = nil, isKeyboard: Bool? = nil, isPointingDevice: Bool? = nil) {
        self.vendorID = vendorID
        self.productID = productID
        self.isKeyboard = isKeyboard
        self.isPointingDevice = isPointingDevice
    }
}

/// Where a rebind applies.
public enum RebindScope: Hashable, Sendable {
    /// The profile's own `simple_modifications`.
    case allDevices
    /// The matching entry of the profile's `devices`, with its own `simple_modifications`.
    case device(DeviceIdentifiers)
}
