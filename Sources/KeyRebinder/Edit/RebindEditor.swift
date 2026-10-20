/// Pure edits of a parsed `karabiner.json`. Every function takes the whole tree plus a profile name and returns
/// a new tree in which only the targeted nodes differ; unknown keys, values and member order are untouched.
public enum RebindEditor {
    static let simpleModificationsKey = "simple_modifications"

    // MARK: Reading

    /// The Simple Modifications of `profile` in `scope`, in file order. Entries overridden by a later entry with the
    /// same `from` (Karabiner keeps the last) are left out unless `includeOverridden` is true.
    public static func rebinds(
        in config: JSONValue, profile: String, scope: RebindScope = .allDevices, includeOverridden: Bool = false
    ) -> [Rebind] {
        guard let profileJSON = ConfigAccess.profile(in: config, named: profile),
              let list = ConfigAccess.list(in: profileJSON, scope: scope, key: simpleModificationsKey) else { return [] }
        return EntryList.entries(list)
            .filter { includeOverridden || !$0.isOverridden }
            .map { Rebind(from: $0.from, to: $0.to, scope: scope, isOverridden: $0.isOverridden) }
    }

    // MARK: Editing

    /// Makes `from` produce `to` in `scope`. Replaces any existing entry with the same `from` (its other keys are
    /// kept); `from == to` removes the entry instead. Missing `simple_modifications` / `devices` entries are created;
    /// a created device entry for a mouse also gets `"ignore": false` so Karabiner actually processes it.
    public static func setRebind(
        in config: JSONValue, profile: String, from: KarabinerEvent, to: KarabinerEvent, scope: RebindScope = .allDevices
    ) throws -> JSONValue {
        if from == to { return try removeRebind(in: config, profile: profile, from: from, scope: scope) }
        return try ConfigAccess.updateProfile(config, named: profile) { profileJSON in
            try ConfigAccess.modifyList(profileJSON, scope: scope, key: simpleModificationsKey, create: true) {
                EntryList.upserting($0, from: from, to: to)
            }
        }
    }

    /// Removes every entry whose `from` is `from` in `scope`. Nothing is created when the list is absent, and an
    /// emptied list stays as an empty array (Karabiner drops it itself on its next save).
    public static func removeRebind(
        in config: JSONValue, profile: String, from: KarabinerEvent, scope: RebindScope = .allDevices
    ) throws -> JSONValue {
        try ConfigAccess.updateProfile(config, named: profile) { profileJSON in
            try ConfigAccess.modifyList(profileJSON, scope: scope, key: simpleModificationsKey, create: false) {
                EntryList.removing($0, from: from)
            }
        }
    }
}
