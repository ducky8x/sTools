import Foundation

/// Settings ▸ Updates (spec 6.2). Sparkle itself isn't integrated yet (that's M8); this just holds the
/// two preferences so the toggles have somewhere to live and M8 can read them directly.
public struct UpdateSettings: SettingsDocument {
    public static let name = "updates"
    public static let version = 1
    public static let defaultValue = UpdateSettings()

    public var checksAutomatically: Bool
    public var installsAutomatically: Bool

    public init(checksAutomatically: Bool = true, installsAutomatically: Bool = true) {
        self.checksAutomatically = checksAutomatically
        self.installsAutomatically = installsAutomatically
    }

    private enum CodingKeys: String, CodingKey {
        case checksAutomatically, installsAutomatically
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        checksAutomatically = try container.decodeIfPresent(Bool.self, forKey: .checksAutomatically) ?? true
        installsAutomatically = try container.decodeIfPresent(Bool.self, forKey: .installsAutomatically) ?? true
    }
}
