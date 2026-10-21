import Foundation

/// Settings ▸ Updates (spec 6.2): whether sTools checks for updates by itself (daily), and whether it also
/// downloads and installs them without asking. The app hands both to Sparkle (spec 6.3) at launch and on change.
/// Installing is off by default, so a found update is shown and the person decides.
public struct UpdateSettings: SettingsDocument {
    public static let name = "updates"
    public static let version = 1
    public static let defaultValue = UpdateSettings()

    public var checksAutomatically: Bool
    public var installsAutomatically: Bool

    public init(checksAutomatically: Bool = true, installsAutomatically: Bool = false) {
        self.checksAutomatically = checksAutomatically
        self.installsAutomatically = installsAutomatically
    }

    private enum CodingKeys: String, CodingKey {
        case checksAutomatically, installsAutomatically
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        checksAutomatically = try container.decodeIfPresent(Bool.self, forKey: .checksAutomatically) ?? true
        installsAutomatically = try container.decodeIfPresent(Bool.self, forKey: .installsAutomatically) ?? false
    }
}
