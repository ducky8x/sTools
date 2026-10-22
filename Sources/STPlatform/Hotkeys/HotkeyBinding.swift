import Foundation

/// One user-defined hotkey: a key combination and the set of actions it performs.
public struct HotkeyBinding: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var combo: HotkeyCombo
    /// A set that remembers the order the user picked. Repeats are dropped on creation and on load.
    /// A binding with no actions is kept (the user may be mid-edit) but never registered.
    public var actions: [HotkeyAction]

    public init(id: UUID = UUID(), combo: HotkeyCombo, actions: [HotkeyAction]) {
        self.id = id
        self.combo = combo
        self.actions = actions.uniqued
    }

    private enum CodingKeys: String, CodingKey { case id, combo, actions }

    /// A bad `id` or `combo` throws, so the list skips the whole binding. Actions are lossy: names this build
    /// doesn't know (one a newer build added, say) are dropped, and the binding stays even when none is left.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let actions = try? container.decodeIfPresent([LossyElement<HotkeyAction>].self, forKey: .actions)
        self.init(id: try container.decode(UUID.self, forKey: .id),
                  combo: try container.decode(HotkeyCombo.self, forKey: .combo),
                  actions: actions?.compactMap(\.value) ?? [])
    }
}

/// The persisted Hotkeys section: `hotkeys.json`.
///
/// Decoding is lossy, so one bad entry never costs the rest (and never makes the settings store move the file
/// aside): a binding that can't be read is skipped, unknown actions are dropped, and a value of the wrong type
/// falls back to its default.
public struct HotkeySettings: SettingsDocument {
    public static let name = "hotkeys"
    /// 2 since the key sets: a version 1 file with no hotkeys at all, the list every earlier build started with, becomes
    /// ⌘1–⌘5 in sidebar order, once (`HotkeyListUpgrade`); a list with hotkeys in it is never moved.
    public static let version = 2
    /// A new install's (no `hotkeys.json` yet): ⌘1–⌘5, one per tool in sidebar order, with hotkeys on. They work only
    /// in sTools and Minecraft by default, so they take no other app's keys from the first launch.
    public static let defaultValue = HotkeySettings(isEnabled: true, bindings: HotkeyKeySet.newInstall.bindings())

    /// The master switch: on for a new install (`defaultValue`), off in a value built without saying (an existing
    /// file without it, tests). While off, nothing is registered with the system.
    public var isEnabled: Bool
    public var bindings: [HotkeyBinding]
    /// Advanced: whether a press shows the on-screen confirmation (a seal and what changed). On by default;
    /// the sound plays either way.
    public var showsConfirmation: Bool
    /// Where hotkeys work: in sTools and Minecraft only (the default), or everywhere.
    public var scope: HotkeyScope

    public init(isEnabled: Bool = false, bindings: [HotkeyBinding] = [], showsConfirmation: Bool = true,
                scope: HotkeyScope = .sToolsAndMinecraft) {
        self.isEnabled = isEnabled
        self.bindings = bindings
        self.showsConfirmation = showsConfirmation
        self.scope = scope
    }

    /// Files from builds that paused hotkeys whenever sTools was in front also carry `pausesWhileSToolsIsActive`.
    /// Hotkeys now pause only while sTools listens for raw keys, so that key is ignored and dropped on the next save.
    private enum CodingKeys: String, CodingKey { case isEnabled, bindings, showsConfirmation, scope }

    /// A file without `scope` (every file from before it existed) or with a scope this build doesn't know gets the
    /// default, In sTools and Minecraft. A list with several keys for Screen Recording alone, one for each of its two
    /// former actions, keeps one (`HotkeyListUpgrade.withOneScreenRecordingKey`).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func flag(_ key: CodingKeys, default value: Bool) -> Bool {
            (try? container.decodeIfPresent(Bool.self, forKey: key)) ?? value
        }
        let bindings = try? container.decodeIfPresent([LossyElement<HotkeyBinding>].self, forKey: .bindings)
        self.init(isEnabled: flag(.isEnabled, default: false),
                  bindings: HotkeyListUpgrade.withOneScreenRecordingKey(bindings?.compactMap(\.value) ?? []),
                  showsConfirmation: flag(.showsConfirmation, default: true),
                  scope: (try? container.decodeIfPresent(HotkeyScope.self, forKey: .scope)) ?? .sToolsAndMinecraft)
    }

    /// Version 1 to 2: an empty list, the one earlier builds left everyone with, becomes the new install's key set
    /// (`HotkeyListUpgrade`); every other list, and every other setting, stays as it is.
    public static func migrate(from oldVersion: Int, _ raw: [String: Any]) throws -> [String: Any] {
        oldVersion == 1 ? HotkeyListUpgrade.upgrade(raw) : raw
    }
}

/// One element of a JSON array, or nil when it can't be decoded. Its own decoding never fails, so decoding
/// `[LossyElement<T>]` always moves on to the next element instead of failing the whole array.
private struct LossyElement<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Value.self)
    }
}
