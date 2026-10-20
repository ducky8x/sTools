extension RebindEditor {
    static let fnFunctionKeysKey = "fn_function_keys"

    /// What F1...F12 send when `fn_function_keys` has no entry for them (Karabiner's built-in defaults); index 0 is F1.
    public static let fnFunctionKeyDefaults: [KarabinerEvent] = [
        .consumer("display_brightness_decrement"),
        .consumer("display_brightness_increment"),
        .other(["apple_vendor_keyboard_key_code": "mission_control"]),
        .other(["apple_vendor_keyboard_key_code": "spotlight"]),
        .consumer("dictation"),
        .other(["generic_desktop": "do_not_disturb"]),
        .consumer("rewind"),
        .consumer("play_or_pause"),
        .consumer("fast_forward"),
        .consumer("mute"),
        .consumer("volume_decrement"),
        .consumer("volume_increment"),
    ]

    /// What F1...F12 produce with fn not held (index 0 is F1): the device's own entry for `scope == .device`, then
    /// the profile's, then Karabiner's default.
    public static func fnFunctionKeys(
        in config: JSONValue, profile: String, scope: RebindScope = .allDevices
    ) -> [KarabinerEvent] {
        let profileJSON = ConfigAccess.profile(in: config, named: profile)
        var lists: [[EntryList.Entry]] = []
        if case .device = scope, let profileJSON, let list = ConfigAccess.list(in: profileJSON, scope: scope, key: fnFunctionKeysKey) {
            lists.append(EntryList.entries(list))
        }
        if let profileJSON, let list = ConfigAccess.list(in: profileJSON, scope: .allDevices, key: fnFunctionKeysKey) {
            lists.append(EntryList.entries(list))
        }
        return fnFunctionKeyDefaults.enumerated().map { offset, fallback in
            let source = KarabinerEvent.key("f\(offset + 1)")
            for list in lists {
                if let entry = list.last(where: { $0.from == source }) { return entry.to }
            }
            return fallback
        }
    }

    /// Sets what F`number` (1...12) produces in `scope`, or with `to == nil` removes the entry so the inherited value
    /// (the profile's, then Karabiner's default) applies again.
    public static func setFnFunctionKey(
        _ number: Int, to: KarabinerEvent?, in config: JSONValue, profile: String, scope: RebindScope = .allDevices
    ) throws -> JSONValue {
        guard (1...12).contains(number) else { throw EditError.invalidFunctionKey(number) }
        let source = KarabinerEvent.key("f\(number)")
        return try ConfigAccess.updateProfile(config, named: profile) { profileJSON in
            try ConfigAccess.modifyList(profileJSON, scope: scope, key: fnFunctionKeysKey, create: to != nil) {
                if let to { EntryList.upserting($0, from: source, to: to) } else { EntryList.removing($0, from: source) }
            }
        }
    }
}
