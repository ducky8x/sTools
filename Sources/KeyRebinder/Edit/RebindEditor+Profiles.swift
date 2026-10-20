extension RebindEditor {
    public static func profileNames(in config: JSONValue) -> [String] {
        ConfigAccess.profiles(in: config).compactMap { $0["name"]?.stringValue }
    }

    /// The profile Karabiner is using: the first one marked `selected`, or the first one when none is.
    public static func selectedProfileName(in config: JSONValue) -> String? {
        ConfigAccess.selectedIndex(in: config).flatMap { ConfigAccess.profiles(in: config)[$0]["name"]?.stringValue }
    }

    /// `base` if no profile uses it, otherwise `base 2`, `base 3`...
    public static func uniqueProfileName(_ base: String, in config: JSONValue) -> String {
        let taken = Set(profileNames(in: config))
        if !taken.contains(base) { return base }
        var number = 2
        while taken.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    /// The name offered for a duplicate of `name`: `name (copy)`, made unique.
    public static func suggestedCopyName(of name: String, in config: JSONValue) -> String {
        uniqueProfileName("\(name) (copy)", in: config)
    }

    /// Appends a new profile with default settings, like Karabiner's own "add profile". It is not selected.
    public static func createEmptyProfile(in config: JSONValue, name: String) throws -> JSONValue {
        let name = try validatedNewName(name, in: config)
        let profile: JSONValue = .object([JSONMember("name", .string(name)), JSONMember("selected", .bool(false))])
        return ConfigAccess.replacingProfiles(config, with: ConfigAccess.profiles(in: config) + [profile])
    }

    /// Appends a full copy of `name` called `newName`. The copy is never selected.
    public static func duplicateProfile(in config: JSONValue, name: String, as newName: String) throws -> JSONValue {
        guard let source = ConfigAccess.profile(in: config, named: name) else { throw EditError.profileNotFound(name) }
        let newName = try validatedNewName(newName, in: config)
        var copy = source.setting("name", .string(newName))
        if copy["selected"] != nil { copy = copy.setting("selected", false) }
        return ConfigAccess.replacingProfiles(config, with: ConfigAccess.profiles(in: config) + [copy])
    }

    public static func renameProfile(in config: JSONValue, name: String, to newName: String) throws -> JSONValue {
        guard ConfigAccess.profileIndex(in: config, named: name) != nil else { throw EditError.profileNotFound(name) }
        let newName = try validatedNewName(newName, in: config, allowing: name)
        return try ConfigAccess.updateProfile(config, named: name) { $0.setting("name", .string(newName)) }
    }

    /// Removes a profile. The selected profile cannot be deleted.
    public static func deleteProfile(in config: JSONValue, name: String) throws -> JSONValue {
        guard let index = ConfigAccess.profileIndex(in: config, named: name) else { throw EditError.profileNotFound(name) }
        guard index != ConfigAccess.selectedIndex(in: config) else { throw EditError.cannotDeleteSelectedProfile(name) }
        var all = ConfigAccess.profiles(in: config)
        all.remove(at: index)
        return ConfigAccess.replacingProfiles(config, with: all)
    }

    /// Moves the profile at `source` so it ends up at index `destination`.
    public static func moveProfile(in config: JSONValue, from source: Int, to destination: Int) throws -> JSONValue {
        var all = ConfigAccess.profiles(in: config)
        for index in [source, destination] where !all.indices.contains(index) {
            throw EditError.profileIndexOutOfRange(index)
        }
        all.insert(all.remove(at: source), at: destination)
        return ConfigAccess.replacingProfiles(config, with: all)
    }

    /// Marks `name` as the one selected profile: its `selected` becomes true and any other `true` becomes false.
    public static func selectProfile(in config: JSONValue, name: String) throws -> JSONValue {
        guard let target = ConfigAccess.profileIndex(in: config, named: name) else { throw EditError.profileNotFound(name) }
        let all = ConfigAccess.profiles(in: config).enumerated().map { index, profile in
            if index == target { return profile.setting("selected", true) }
            return profile["selected"]?.boolValue == true ? profile.setting("selected", false) : profile
        }
        return ConfigAccess.replacingProfiles(config, with: all)
    }

    private static func validatedNewName(_ name: String, in config: JSONValue, allowing existing: String? = nil) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EditError.emptyProfileName }
        if trimmed != existing, profileNames(in: config).contains(trimmed) { throw EditError.profileNameTaken(trimmed) }
        return trimmed
    }
}
