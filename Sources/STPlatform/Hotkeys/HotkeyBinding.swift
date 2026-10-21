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
    public static let version = 1
    public static let defaultValue = HotkeySettings()

    /// The master switch. Off by default; while off, nothing is registered with the system.
    public var isEnabled: Bool
    public var bindings: [HotkeyBinding]
    /// Advanced: whether a press shows the on-screen confirmation (a seal and what changed). On by default;
    /// the sound plays either way.
    public var showsConfirmation: Bool
    /// Advanced: whether hotkeys pause while sTools is the active app, so every key works in sTools itself
    /// (typing, recording a combination, testing keys). On by default. Builds without it ignore the key.
    public var pausesWhileSToolsIsActive: Bool

    public init(isEnabled: Bool = false, bindings: [HotkeyBinding] = [], showsConfirmation: Bool = true,
                pausesWhileSToolsIsActive: Bool = true) {
        self.isEnabled = isEnabled
        self.bindings = bindings
        self.showsConfirmation = showsConfirmation
        self.pausesWhileSToolsIsActive = pausesWhileSToolsIsActive
    }

    private enum CodingKeys: String, CodingKey { case isEnabled, bindings, showsConfirmation, pausesWhileSToolsIsActive }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func flag(_ key: CodingKeys, default value: Bool) -> Bool {
            (try? container.decodeIfPresent(Bool.self, forKey: key)) ?? value
        }
        let bindings = try? container.decodeIfPresent([LossyElement<HotkeyBinding>].self, forKey: .bindings)
        self.init(isEnabled: flag(.isEnabled, default: false),
                  bindings: bindings?.compactMap(\.value) ?? [],
                  showsConfirmation: flag(.showsConfirmation, default: true),
                  pausesWhileSToolsIsActive: flag(.pausesWhileSToolsIsActive, default: true))
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
