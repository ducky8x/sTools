import Foundation

/// App-wide behavior switches (Settings ▸ General ▸ Advanced). Stored as `general.json`.
public struct GeneralSettings: SettingsDocument {
    public static let name = "general"
    public static let version = 1
    public static let defaultValue = GeneralSettings(restoreToolsAtQuit: false, toolsOnAtQuit: [])

    /// Whether the tools that were on at quit are switched back on at the next launch.
    public var restoreToolsAtQuit: Bool
    /// Identifiers of the tools that were on when the app last quit. Only used when `restoreToolsAtQuit` is on.
    public var toolsOnAtQuit: [String]

    public init(restoreToolsAtQuit: Bool = false, toolsOnAtQuit: [String] = []) {
        self.restoreToolsAtQuit = restoreToolsAtQuit
        self.toolsOnAtQuit = toolsOnAtQuit
    }

    private enum CodingKeys: String, CodingKey {
        case restoreToolsAtQuit, toolsOnAtQuit
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        restoreToolsAtQuit = try container.decodeIfPresent(Bool.self, forKey: .restoreToolsAtQuit) ?? false
        toolsOnAtQuit = try container.decodeIfPresent([String].self, forKey: .toolsOnAtQuit) ?? []
    }
}
