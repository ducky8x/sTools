/// Navigation shared by the editors. Everything here is pure: trees in, trees out.
enum ConfigAccess {
    static func profiles(in config: JSONValue) -> [JSONValue] {
        config["profiles"]?.arrayValue ?? []
    }

    static func profileIndex(in config: JSONValue, named name: String) -> Int? {
        profiles(in: config).firstIndex { $0["name"]?.stringValue == name }
    }

    static func profile(in config: JSONValue, named name: String) -> JSONValue? {
        profileIndex(in: config, named: name).map { profiles(in: config)[$0] }
    }

    /// Karabiner treats the first profile marked `selected` as current, and the first profile when none is.
    static func selectedIndex(in config: JSONValue) -> Int? {
        let all = profiles(in: config)
        return all.firstIndex { $0["selected"]?.boolValue == true } ?? (all.isEmpty ? nil : 0)
    }

    static func replacingProfiles(_ config: JSONValue, with profiles: [JSONValue]) -> JSONValue {
        config.setting("profiles", .array(profiles))
    }

    static func updateProfile(
        _ config: JSONValue, named name: String, _ transform: (JSONValue) throws -> JSONValue
    ) throws -> JSONValue {
        guard let index = profileIndex(in: config, named: name) else { throw EditError.profileNotFound(name) }
        var all = profiles(in: config)
        all[index] = try transform(all[index])
        return replacingProfiles(config, with: all)
    }

    // MARK: Devices

    /// Index of the `devices` entry whose identifiers equal `identifiers` (an absent field means 0 or false,
    /// as in Karabiner). Extra identifier fields such as `device_address` do not take part.
    static func deviceIndex(in profile: JSONValue, matching identifiers: DeviceIdentifiers) -> Int? {
        profile["devices"]?.arrayValue?.firstIndex { identifiers.matches($0["identifiers"]) }
    }

    static func identifiersJSON(_ identifiers: DeviceIdentifiers) -> JSONValue {
        var members: [JSONMember] = []
        if let isKeyboard = identifiers.isKeyboard { members.append(JSONMember("is_keyboard", .bool(isKeyboard))) }
        if let isPointing = identifiers.isPointingDevice { members.append(JSONMember("is_pointing_device", .bool(isPointing))) }
        if let productID = identifiers.productID { members.append(JSONMember("product_id", .int(productID))) }
        if let vendorID = identifiers.vendorID { members.append(JSONMember("vendor_id", .int(vendorID))) }
        return .object(members)
    }

    // MARK: Entry lists (simple_modifications, fn_function_keys)

    /// The array at `key` for `scope`; `nil` when the profile, device or array is absent.
    static func list(in profile: JSONValue, scope: RebindScope, key: String) -> [JSONValue]? {
        switch scope {
        case .allDevices:
            return profile[key]?.arrayValue
        case .device(let identifiers):
            guard let index = deviceIndex(in: profile, matching: identifiers) else { return nil }
            return profile["devices"]?.arrayValue?[index][key]?.arrayValue
        }
    }

    /// Applies `transform` to the entry list at `key` for `scope`. A missing list is created only when `create` is true
    /// (a missing device entry too); otherwise the profile is returned unchanged.
    static func modifyList(
        _ profile: JSONValue, scope: RebindScope, key: String, create: Bool, _ transform: ([JSONValue]) -> [JSONValue]
    ) throws -> JSONValue {
        switch scope {
        case .allDevices:
            let existing = profile[key]
            if let existing, !existing.isArray { throw EditError.malformedConfig("profile \(key) is not an array") }
            if existing == nil, !create { return profile }
            return profile.setting(key, .array(transform(existing?.arrayValue ?? [])))
        case .device(let identifiers):
            if let devices = profile["devices"], !devices.isArray { throw EditError.malformedConfig("profile devices is not an array") }
            var devices = profile["devices"]?.arrayValue ?? []
            guard let index = devices.firstIndex(where: { identifiers.matches($0["identifiers"]) }) else {
                guard create else { return profile }
                var members = [JSONMember("identifiers", identifiersJSON(identifiers))]
                // Karabiner ignores mice by default; without this the new rebinds would never apply.
                if identifiers.isPointingDevice == true, identifiers.isKeyboard != true {
                    members.append(JSONMember("ignore", .bool(false)))
                }
                members.append(JSONMember(key, .array(transform([]))))
                devices.append(.object(members))
                return profile.setting("devices", .array(devices))
            }
            let existing = devices[index][key]
            if let existing, !existing.isArray { throw EditError.malformedConfig("device \(key) is not an array") }
            if existing == nil, !create { return profile }
            devices[index] = devices[index].setting(key, .array(transform(existing?.arrayValue ?? [])))
            return profile.setting("devices", .array(devices))
        }
    }
}

extension DeviceIdentifiers {
    func matches(_ json: JSONValue?) -> Bool {
        (vendorID ?? 0) == (json?["vendor_id"]?.intValue ?? 0)
            && (productID ?? 0) == (json?["product_id"]?.intValue ?? 0)
            && (isKeyboard ?? false) == (json?["is_keyboard"]?.boolValue ?? false)
            && (isPointingDevice ?? false) == (json?["is_pointing_device"]?.boolValue ?? false)
    }
}

/// Reads and rewrites `{ "from": ..., "to": [...] }` entry lists.
enum EntryList {
    struct Entry {
        var from: KarabinerEvent
        var to: KarabinerEvent
        var isOverridden: Bool
    }

    /// The `from` event of one list item; `nil` for items that are not a usable entry.
    static func from(of item: JSONValue) -> KarabinerEvent? {
        guard case .object(let members) = item["from"], !members.isEmpty, item["to"] != nil else { return nil }
        return KarabinerEvent(json: .object(members.filter { !$0.key.isEmpty }))
    }

    /// Entries in file order. Karabiner keeps the last entry for a repeated `from`, so earlier ones are overridden.
    static func entries(_ items: [JSONValue]) -> [Entry] {
        let parsed = items.compactMap { item -> (KarabinerEvent, KarabinerEvent)? in
            from(of: item).flatMap { from in item["to"].map { (from, KarabinerEvent(toValue: $0)) } }
        }
        return parsed.enumerated().map { position, pair in
            Entry(from: pair.0, to: pair.1, isOverridden: parsed[(position + 1)...].contains { $0.0 == pair.0 })
        }
    }

    /// Sets the entry for `from`: edits the winning entry in place (keeping its unknown keys and position) and drops
    /// the overridden duplicates; appends a new entry when there is none.
    static func upserting(_ items: [JSONValue], from event: KarabinerEvent, to: KarabinerEvent) -> [JSONValue] {
        let matches = items.indices.filter { from(of: items[$0]) == event }
        guard let winner = matches.last else {
            return items + [.object([JSONMember("from", event.json), JSONMember("to", to.toValue)])]
        }
        var result = items
        result[winner] = result[winner].setting("to", to.toValue)
        for index in matches.dropLast().reversed() { result.remove(at: index) }
        return result
    }

    static func removing(_ items: [JSONValue], from event: KarabinerEvent) -> [JSONValue] {
        items.filter { from(of: $0) != event }
    }
}
