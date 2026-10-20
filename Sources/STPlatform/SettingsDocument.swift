import Foundation

/// A versioned, persisted settings document. Each conforming type is stored as one
/// JSON file, `<name>.json`, inside the `SettingsStore` directory.
///
/// A document must encode to a JSON object (a keyed container), because migrations
/// operate on the raw dictionary.
public protocol SettingsDocument: Codable, Equatable, Sendable {
    /// File stem and stable identity of the document. Never change it once shipped.
    static var name: String { get }
    /// Current schema version, starting at 1. Bump it whenever the stored shape changes.
    static var version: Int { get }
    /// Value used when nothing usable is on disk.
    static var defaultValue: Self { get }
    /// Upgrades the raw stored value from `oldVersion` to `oldVersion + 1`.
    /// The store calls this once per step until the value reaches `version`.
    static func migrate(from oldVersion: Int, _ raw: [String: Any]) throws -> [String: Any]
}

extension SettingsDocument {
    /// Additive changes (new optional or defaulted keys) need no migration code.
    public static func migrate(from oldVersion: Int, _ raw: [String: Any]) throws -> [String: Any] {
        raw
    }
}
