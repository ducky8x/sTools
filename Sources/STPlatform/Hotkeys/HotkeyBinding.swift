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

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(UUID.self, forKey: .id),
                  combo: try container.decode(HotkeyCombo.self, forKey: .combo),
                  actions: try container.decode([HotkeyAction].self, forKey: .actions))
    }
}

/// The persisted Hotkeys section: `hotkeys.json`.
public struct HotkeySettings: SettingsDocument {
    public static let name = "hotkeys"
    public static let version = 1
    public static let defaultValue = HotkeySettings()

    /// The master switch. Off by default; while off, nothing is registered with the system.
    public var isEnabled: Bool
    public var bindings: [HotkeyBinding]

    public init(isEnabled: Bool = false, bindings: [HotkeyBinding] = []) {
        self.isEnabled = isEnabled
        self.bindings = bindings
    }

    private enum CodingKeys: String, CodingKey { case isEnabled, bindings }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
                  bindings: try container.decodeIfPresent([HotkeyBinding].self, forKey: .bindings) ?? [])
    }
}
